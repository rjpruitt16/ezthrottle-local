defmodule EzthrottleLocal.RetryPolicyTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias EzthrottleLocal.{AccountQueueRegistry, Cluster, IdempotentStore, Job}
  alias EzthrottleLocalWeb.JobController

  # Plays back a script of {status, headers} responses (the last one repeats)
  # and reports every attempt as {:attempt, path, monotonic_ms}.
  defmodule ScriptedPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")

    def call(conn, %{script: script, test_pid: test_pid}) do
      send(test_pid, {:attempt, conn.request_path, System.monotonic_time(:millisecond)})

      {status, headers} =
        Agent.get_and_update(script, fn
          [only] -> {only, [only]}
          [next | rest] -> {next, rest}
        end)

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      send_resp(conn, status, ~s({"status":#{status}}))
    end
  end

  defmodule WebhookPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"job_id" => _} = payload} -> send(test_pid, {:webhook, payload})
        _ -> :ok
      end

      send_resp(conn, 200, "ok")
    end
  end

  setup do
    previous =
      for key <- [:default_rps, :dispatch_retry_ms],
          do: {key, Application.get_env(:ezthrottle_local, key)}

    Application.put_env(:ezthrottle_local, :default_rps, 100.0)
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 0)

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:ezthrottle_local, key),
          else: Application.put_env(:ezthrottle_local, key, value)
      end
    end)

    {:ok, webhook: start_server(WebhookPlug, self())}
  end

  defp start_server(plug, opts) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: :"retry_#{port}")
    )

    "http://127.0.0.1:#{port}"
  end

  defp upstream(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    start_server(ScriptedPlug, %{script: agent, test_pid: self()})
  end

  defp submit(url, webhook, extra \\ %{}) do
    {:ok, job} =
      %{
        "user_id" => "retry-user",
        "idempotent_key" => "retry-#{System.unique_integer([:positive])}",
        "url" => url,
        "method" => "POST",
        "webhook_url" => webhook
      }
      |> Map.merge(extra)
      |> Job.new()

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")
    job
  end

  defp count_attempts(acc \\ 0) do
    receive do
      {:attempt, _, _} -> count_attempts(acc + 1)
    after
      0 -> acc
    end
  end

  test "defaults to four retries", %{webhook: webhook} do
    submit(upstream([{500, []}]) <> "/x", webhook)
    assert_receive {:webhook, %{"status" => "failed"}}, 10_000
    assert count_attempts() == 5
  end

  test "max_retries 0 makes a single attempt", %{webhook: webhook} do
    submit(upstream([{502, []}]) <> "/x", webhook, %{"max_retries" => 0})
    assert_receive {:webhook, %{"status" => "failed"}}, 5_000
    assert count_attempts() == 1
  end

  test "-1 retries past the default until the job succeeds", %{webhook: webhook} do
    script = List.duplicate({503, []}, 7) ++ [{200, []}]
    submit(upstream(script) <> "/x", webhook, %{"max_retries" => -1})
    assert_receive {:webhook, %{"status" => "completed"}}, 15_000
    assert count_attempts() == 8
  end

  test "-1 still stops at execute_before", %{webhook: webhook} do
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 300)
    before = System.system_time(:millisecond) + 1_200

    submit(upstream([{500, []}]) <> "/x", webhook, %{
      "max_retries" => -1,
      "execute_before" => before
    })

    assert_receive {:webhook, %{"status" => "failed", "reason" => reason}}, 5_000
    assert reason =~ "retry_window_exhausted" or reason == "execution_deadline_exceeded"
    stopped = count_attempts()
    Process.sleep(700)
    assert count_attempts() == 0, "attempts continued after #{stopped} and the job failed"
  end

  test "other 4xx responses are not retried", %{webhook: webhook} do
    submit(upstream([{400, []}]) <> "/x", webhook)
    assert_receive {:webhook, %{"response_status" => 400}}, 5_000
    assert count_attempts() == 1
  end

  test "429 honors Retry-After", %{webhook: webhook} do
    submit(upstream([{429, [{"retry-after", "1"}]}, {200, []}]) <> "/x", webhook)
    assert_receive {:attempt, _, first}, 5_000
    assert_receive {:attempt, _, second}, 5_000
    assert second - first >= 950
    assert_receive {:webhook, %{"status" => "completed"}}, 5_000
  end

  test "a job backing off frees the slot for others", %{webhook: webhook} do
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 2_000)
    {:ok, agent} = Agent.start_link(fn -> [{500, []}] end)

    defmodule SplitPlug do
      import Plug.Conn
      def init(opts), do: opts
      def call(%{request_path: "/.well-known/l8"} = conn, _), do: send_resp(conn, 404, "")

      def call(conn, test_pid) do
        send(test_pid, {:attempt, conn.request_path, System.monotonic_time(:millisecond)})

        if conn.request_path == "/a",
          do: send_resp(conn, 500, "no"),
          else: send_resp(conn, 200, "ok")
      end
    end

    Agent.stop(agent)
    base = start_server(SplitPlug, self())
    started = System.monotonic_time(:millisecond)
    submit(base <> "/a", webhook)
    assert_receive {:attempt, "/a", _}, 5_000
    submit(base <> "/b", webhook)
    assert_receive {:attempt, "/b", at}, 3_000
    assert at - started < 1_500
  end

  test "a retryable failure halves the queue's pace and persists the attempt", %{webhook: webhook} do
    Application.put_env(:ezthrottle_local, :default_rps, 8.0)
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 60_000)
    base = upstream([{500, []}])
    job = submit(base <> "/x", webhook)
    assert_receive {:attempt, _, _}, 5_000

    queue =
      wait_for(fn ->
        Cluster.lookup_account_queue(base, Job.queue_key(job)) ||
          Cluster.lookup_account_queue(base, :shared)
      end)

    assert wait_for(fn -> :sys.get_state(queue).rps == 4.0 end)
    assert wait_for(fn -> IdempotentStore.get_job(job.id).attempts == 1 end)
    assert IdempotentStore.get_status(job.id) == "queued"
  end

  test "validates max_retries and lets the header override the body" do
    base = %{
      "user_id" => "u",
      "idempotent_key" => "k",
      "url" => "http://x",
      "method" => "GET",
      "webhook_url" => "http://w"
    }

    for bad <- [-2, 101, "abc"] do
      assert {:error, msg} = Job.new(Map.put(base, "max_retries", bad))
      assert msg =~ "max_retries"
    end

    params =
      Map.merge(base, %{
        "idempotent_key" => "hdr-#{System.unique_integer([:positive])}",
        "max_retries" => 2
      })

    conn =
      build_conn(:post, "/jobs", params)
      |> Plug.Conn.put_req_header("x-aqueduct-max-retries", "-1")
      |> JobController.create(params)

    assert conn.status == 201
    job_id = Jason.decode!(conn.resp_body)["job_id"]
    assert IdempotentStore.get_job(job_id).max_retries == -1
  end

  defp wait_for(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      value = fun.()
      if value in [nil, false], do: Process.sleep(20)
      value
    end)
    |> Enum.find(fn value ->
      value not in [nil, false] or System.monotonic_time(:millisecond) > deadline
    end)
  end
end
