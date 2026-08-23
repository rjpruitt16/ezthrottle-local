defmodule EzthrottleLocal.PoolDispatchTest do
  @moduledoc """
  End-to-end proof that a job submitted with pool_id (no url) actually
  resolves through the pool and reaches a real registered member's
  address, exercising the full path: AccountQueueRegistry -> UrlActor ->
  AccountQueue -> Pool.pick -> execute -> make_request. Mirrors Aquifer's
  pool_dispatch_test.go, the same class of test that caught a real
  lazy-pool-creation bug in the Go implementation before this port.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.IdempotentStore

  defmodule EchoPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :hits_agent)
      Agent.update(agent, &(&1 + 1))
      send_resp(conn, 200, "ok")
    end
  end

  defmodule FailingPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :hits_agent)
      Agent.update(agent, &(&1 + 1))
      send_resp(conn, 500, "failed")
    end
  end

  defmodule WebhookPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :webhook_hit)
      send_resp(conn, 200, "ok")
    end
  end

  defmodule JsonWebhookPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"job_id" => _} = payload} -> send(test_pid, {:webhook_payload, payload})
        _ -> :ok
      end

      send_resp(conn, 200, "ok")
    end
  end

  defp start_server(plug, opts) do
    port = Enum.random(20_000..60_000)
    child_id = :"pool_dispatch_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  test "a pool-backed job dispatches to a registered member" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    member_url = start_server(EchoPlug, hits_agent: hits)
    webhook_url = start_server(WebhookPlug, test_pid: self())

    pool_id = "workers-#{System.unique_integer([:positive])}"
    :ok = EzthrottleLocal.PoolRegistry.register(pool_id, "w1", member_url, 20.0, 30_000)

    {:ok, job} =
      Job.new(%{
        "user_id" => "user-1",
        "idempotent_key" => "pool-dispatch-#{System.unique_integer([:positive])}",
        "pool_id" => pool_id,
        "method" => "POST",
        "webhook_url" => webhook_url
      })

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")

    assert_receive :webhook_hit, 3_000
    assert Agent.get(hits, & &1) == 1
  end

  test "a pool-backed job waits until a member registers" do
    prev = Application.get_env(:ezthrottle_local, :no_pool_members_retry_ms)
    Application.put_env(:ezthrottle_local, :no_pool_members_retry_ms, 10)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezthrottle_local, :no_pool_members_retry_ms)
        val -> Application.put_env(:ezthrottle_local, :no_pool_members_retry_ms, val)
      end
    end)

    {:ok, hits} = Agent.start_link(fn -> 0 end)
    member_url = start_server(EchoPlug, hits_agent: hits)
    webhook_url = start_server(WebhookPlug, test_pid: self())

    pool_id = "delayed-workers-#{System.unique_integer([:positive])}"

    {:ok, job} =
      Job.new(%{
        "user_id" => "user-1",
        "idempotent_key" => "delayed-pool-#{System.unique_integer([:positive])}",
        "pool_id" => pool_id,
        "method" => "POST",
        "webhook_url" => webhook_url
      })

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")

    refute_receive :webhook_hit, 50
    assert IdempotentStore.get_status(job.id) == "queued"

    :ok = EzthrottleLocal.PoolRegistry.register(pool_id, "w1", member_url, 20.0, 30_000)

    assert_receive :webhook_hit, 3_000
    assert Agent.get(hits, & &1) == 1
    assert IdempotentStore.get_status(job.id) == "completed"
  end

  test "a pool-backed job fails over from a 500 member to a healthy member" do
    prev_retry = Application.get_env(:ezthrottle_local, :dispatch_retry_ms)
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 0)

    on_exit(fn ->
      case prev_retry do
        nil -> Application.delete_env(:ezthrottle_local, :dispatch_retry_ms)
        val -> Application.put_env(:ezthrottle_local, :dispatch_retry_ms, val)
      end
    end)

    {:ok, bad_hits} = Agent.start_link(fn -> 0 end)
    {:ok, good_hits} = Agent.start_link(fn -> 0 end)
    bad_url = start_server(FailingPlug, hits_agent: bad_hits)
    good_url = start_server(EchoPlug, hits_agent: good_hits)
    webhook_url = start_server(JsonWebhookPlug, test_pid: self())

    pool_id = "failover-workers-#{System.unique_integer([:positive])}"
    :ok = EzthrottleLocal.PoolRegistry.register(pool_id, "bad", bad_url, 10.0, 30_000)
    :ok = EzthrottleLocal.PoolRegistry.register(pool_id, "good", good_url, 10.0, 30_000)

    {:ok, job} =
      Job.new(%{
        "user_id" => "user-1",
        "idempotent_key" => "pool-failover-#{System.unique_integer([:positive])}",
        "pool_id" => pool_id,
        "method" => "POST",
        "webhook_url" => webhook_url
      })

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")

    assert_receive {:webhook_payload, %{"status" => "completed"}}, 3_000
    assert Agent.get(bad_hits, & &1) > 0
    assert Agent.get(good_hits, & &1) > 0
    assert IdempotentStore.get_status(job.id) == "completed"

    [bad_member] =
      pool_id
      |> EzthrottleLocal.PoolRegistry.get_or_create()
      |> EzthrottleLocal.Pool.snapshot()
      |> Enum.filter(&(&1.id == "bad"))

    assert bad_member.reputation < 1.0
  end

  test "a pool-backed job treats final repeated 500 as failed" do
    prev_retry = Application.get_env(:ezthrottle_local, :dispatch_retry_ms)
    Application.put_env(:ezthrottle_local, :dispatch_retry_ms, 0)

    on_exit(fn ->
      case prev_retry do
        nil -> Application.delete_env(:ezthrottle_local, :dispatch_retry_ms)
        val -> Application.put_env(:ezthrottle_local, :dispatch_retry_ms, val)
      end
    end)

    {:ok, hits} = Agent.start_link(fn -> 0 end)
    member_url = start_server(FailingPlug, hits_agent: hits)
    webhook_url = start_server(JsonWebhookPlug, test_pid: self())

    pool_id = "final-500-workers-#{System.unique_integer([:positive])}"
    :ok = EzthrottleLocal.PoolRegistry.register(pool_id, "bad", member_url, 10.0, 30_000)

    {:ok, job} =
      Job.new(%{
        "user_id" => "user-1",
        "idempotent_key" => "pool-final-500-#{System.unique_integer([:positive])}",
        "pool_id" => pool_id,
        "method" => "POST",
        "webhook_url" => webhook_url
      })

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")

    assert_receive {:webhook_payload, %{"status" => "failed", "response_status" => 500}}, 3_000
    assert IdempotentStore.get_status(job.id) == "failed"
  end
end
