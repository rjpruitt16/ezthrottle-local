defmodule EzthrottleLocal.WebhookPacingTest do
  @moduledoc """
  Mirrors Aquifer's webhook_pacing_test.go: webhook delivery now flows
  through AccountQueueRegistry.enqueue_webhook/4, the same domain-keyed
  account-queue pacing machinery as forward dispatch, instead of firing
  immediately via EzthrottleLocal.Webhook with a fixed retry schedule.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.IdempotentStore

  defmodule OkPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "ok")
    end
  end

  defmodule HitCountingPlug do
    import Plug.Conn

    def init(opts), do: opts

    # L8.ensure_trust probes GET /.well-known/l8 before every webhook-delivery
    # dispatch (see Job.webhook_delivery_job?/1) -- skip it here so only the
    # actual webhook POST counts as a hit, mirroring Aquifer's skipL8Probe
    # test helper.
    def call(%{request_path: "/.well-known/l8"} = conn, _opts) do
      send_resp(conn, 404, "")
    end

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :hit)
      send_resp(conn, 200, "ok")
    end
  end

  defmodule RpsHeaderPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("x-aqueduct-rps", "1")
      |> send_resp(200, "ok")
    end
  end

  defmodule L8ReceiverPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, _opts) do
      json(conn, 200, EzthrottleLocal.L8.meta(conn.host))
    end

    def call(%{request_path: "/l8/challenge"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      {:ok, params} = Jason.decode(body)

      case EzthrottleLocal.L8.handle_challenge(params) do
        {:ok, response} -> json(conn, 200, response)
        {:error, _} -> send_resp(conn, 400, "")
      end
    end

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:headers, conn.req_headers})
      send_resp(conn, 200, "ok")
    end

    defp json(conn, status, data) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
    end
  end

  defp start_server(plug, opts \\ []) do
    port = Enum.random(20_000..60_000)
    child_id = :"webhook_pacing_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  defp url_actor_state_for(url) do
    uri = URI.parse(url)
    port_suffix = if uri.port, do: ":#{uri.port}", else: ""
    url_key = "#{uri.scheme}://#{uri.host}#{port_suffix}"
    [{^url_key, pid}] = :ets.lookup(:url_actors, url_key)
    :sys.get_state(pid)
  end

  test "a webhook-delivery job does not enqueue its own webhook" do
    upstream_url = start_server(OkPlug)
    webhook_url = start_server(HitCountingPlug, test_pid: self())

    job = %Job{
      id: "no-chain-#{System.unique_integer([:positive])}",
      user_id: "user-1",
      idempotent_key: "no-chain-key-#{System.unique_integer([:positive])}",
      url: upstream_url,
      method: "GET",
      headers: %{},
      webhook_url: webhook_url,
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job)

    assert_receive :hit, 3_000
    refute_receive :hit, 300
  end

  test "EnqueueWebhook is deduped for the same originating job id" do
    webhook_url = start_server(HitCountingPlug, test_pid: self())
    job_id = "dedup-#{System.unique_integer([:positive])}"

    AccountQueueRegistry.enqueue_webhook(job_id, "user-1", webhook_url, %{status: "completed"})
    AccountQueueRegistry.enqueue_webhook(job_id, "user-1", webhook_url, %{status: "completed"})

    assert_receive :hit, 3_000
    refute_receive :hit, 300
  end

  test "webhook delivery is paced by the account queue via X-Aqueduct-Rps" do
    webhook_url = start_server(RpsHeaderPlug)
    job_id = "paced-#{System.unique_integer([:positive])}"

    AccountQueueRegistry.enqueue_webhook(job_id, "user-1", webhook_url, %{status: "completed"})

    rps =
      Enum.reduce_while(1..300, nil, fn _, _ ->
        state = url_actor_state_for(webhook_url)

        case Map.get(state.queues, :shared) do
          nil ->
            Process.sleep(10)
            {:cont, nil}

          pid ->
            case EzthrottleLocal.AccountQueue.get_rps(pid) do
              rps when rps > 0 and rps <= 1.01 ->
                {:halt, rps}

              _ ->
                Process.sleep(10)
                {:cont, nil}
            end
        end
      end)

    assert rps != nil && rps <= 1.01,
           "expected the webhook account queue's rps to settle at the receiver's advertised 1, got #{inspect(rps)}"
  end

  test "webhook delivery is L8 signed" do
    webhook_url = start_server(L8ReceiverPlug, test_pid: self())
    job_id = "l8-signed-#{System.unique_integer([:positive])}"

    AccountQueueRegistry.enqueue_webhook(job_id, "user-1", webhook_url, %{status: "completed"})

    assert_receive {:headers, headers}, 3_000
    header_map = Map.new(headers)

    for name <- ["x-l8-delivery-id", "x-l8-timestamp", "x-l8-key-id", "x-l8-signature"] do
      assert Map.has_key?(header_map, name),
             "expected webhook delivery to carry #{name}, got: #{inspect(headers)}"
    end
  end

  test "forward dispatch is not L8 signed" do
    receiver_url = start_server(L8ReceiverPlug, test_pid: self())
    sink_url = start_server(OkPlug)

    job = %Job{
      id: "no-l8-#{System.unique_integer([:positive])}",
      user_id: "user-1",
      idempotent_key: "no-l8-key-#{System.unique_integer([:positive])}",
      url: receiver_url,
      method: "GET",
      headers: %{},
      webhook_url: sink_url,
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job)

    assert_receive {:headers, headers}, 3_000
    header_map = Map.new(headers)

    for name <- ["x-l8-delivery-id", "x-l8-timestamp", "x-l8-key-id", "x-l8-signature"] do
      refute Map.has_key?(header_map, name),
             "forward dispatch must never carry #{name}, got: #{inspect(headers)}"
    end
  end

  test "webhook-delivery jobs are excluded from the idempotency ledger" do
    webhook_url = start_server(HitCountingPlug, test_pid: self())

    real_job = %Job{
      id: "ledger-real-#{System.unique_integer([:positive])}",
      user_id: "user-1",
      idempotent_key: "ledger-real-key-#{System.unique_integer([:positive])}",
      url: webhook_url,
      method: "GET",
      headers: %{},
      webhook_url: webhook_url,
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    IdempotentStore.clear_ledger()
    :ok = IdempotentStore.check_or_insert(real_job)

    AccountQueueRegistry.enqueue_webhook(
      "some-other-job-#{System.unique_integer([:positive])}",
      "user-1",
      webhook_url,
      %{status: "completed"}
    )

    assert_receive :hit, 3_000

    entries = IdempotentStore.list_ledger()
    assert length(entries) == 1
    assert hd(entries).job_id == real_job.id
  end
end
