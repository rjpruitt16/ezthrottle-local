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

  defmodule WebhookPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :webhook_hit)
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

  test "a pool-backed job fails cleanly when nobody has registered to that pool" do
    webhook_url = start_server(WebhookPlug, test_pid: self())

    pool_id = "nobody-registered-#{System.unique_integer([:positive])}"

    {:ok, job} =
      Job.new(%{
        "user_id" => "user-1",
        "idempotent_key" => "empty-pool-#{System.unique_integer([:positive])}",
        "pool_id" => pool_id,
        "method" => "POST",
        "webhook_url" => webhook_url
      })

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")

    assert_receive :webhook_hit, 3_000

    stored = IdempotentStore.get_job(job.id)
    assert stored != nil
    assert IdempotentStore.get_status(job.id) == "failed"
  end
end
