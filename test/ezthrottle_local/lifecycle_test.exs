defmodule EzthrottleLocal.LifecycleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias EzthrottleLocal.{IdempotentStore, Lifecycle}
  alias EzthrottleLocalWeb.{HealthController, JobController}

  @endpoint EzthrottleLocalWeb.Endpoint

  defmodule SlowPlug do
    import Plug.Conn
    def init(opts), do: opts
    def call(%{request_path: "/.well-known/l8"} = conn, _), do: send_resp(conn, 404, "")

    def call(conn, delay_ms) do
      Process.sleep(delay_ms)
      send_resp(conn, 200, ~s({"ok":true}))
    end
  end

  defmodule WebhookPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"job_id" => id}} -> send(test_pid, {:webhook, id})
        _ -> :ok
      end

      send_resp(conn, 200, "ok")
    end
  end

  setup do
    # pending_count/0 is node-wide; other tests' leftover retries would make
    # drain correctly wait on them.
    IdempotentStore.clear_ledger()
    Lifecycle.reset()
    on_exit(&Lifecycle.reset/0)
    :ok
  end

  defp start_server(plug, opts) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: :"lifecycle_#{port}")
    )

    "http://127.0.0.1:#{port}"
  end

  defp submit(url, webhook) do
    params = %{
      "user_id" => "lifecycle-user",
      "idempotent_key" => "lifecycle-#{System.unique_integer([:positive])}",
      "url" => url,
      "method" => "POST",
      "webhook_url" => webhook
    }

    conn = JobController.create(build_conn(:post, "/jobs", params), params)
    assert conn.status == 201
    Jason.decode!(conn.resp_body)["job_id"]
  end

  test "a draining node fails /ready and rejects new work with the draining headers" do
    assert json_response(HealthController.ready(build_conn(), %{}), 200) == %{"status" => "ready"}

    Lifecycle.begin_drain()

    ready = HealthController.ready(build_conn(), %{})
    assert ready.status == 503
    assert Plug.Conn.get_resp_header(ready, "x-aqueduct-node-state") == ["draining"]
    assert Plug.Conn.get_resp_header(ready, "retry-after") == ["5"]

    jobs = post(build_conn(), "/jobs", %{"user_id" => "u"})
    assert jobs.status == 503
    proxy = post(build_conn(), "/proxy", %{"user_id" => "u"})
    assert proxy.status == 503

    health = json_response(get(build_conn(), "/health"), 200)
    assert health["status"] == "draining"
  end

  test "drain waits for accepted work and its webhook, then returns" do
    upstream = start_server(SlowPlug, 800)
    webhook = start_server(WebhookPlug, self())
    job_id = submit(upstream, webhook)

    started = System.monotonic_time(:millisecond)
    assert Lifecycle.drain(timeout_ms: 10_000, quiesce_ms: 0) == :drained
    assert System.monotonic_time(:millisecond) - started >= 500
    assert_received {:webhook, ^job_id}
    assert IdempotentStore.get_status(job_id) == "completed"
    assert IdempotentStore.pending_count() == 0
  end

  test "drain is bounded by the shutdown deadline and leaves work for recovery" do
    upstream = start_server(SlowPlug, 3_000)
    job_id = submit(upstream, start_server(WebhookPlug, self()))

    assert {:timeout, pending} = Lifecycle.drain(timeout_ms: 400, quiesce_ms: 0)
    assert pending >= 1
    assert IdempotentStore.get_status(job_id) in ["queued", "in_flight"]
  end
end
