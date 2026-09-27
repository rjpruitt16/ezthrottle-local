defmodule EzthrottleLocal.IdleLifecycleTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Cluster

  defmodule OkPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "ok")
    end
  end

  setup do
    previous_idle_timeout_seconds = System.get_env("EZTHROTTLE_IDLE_TIMEOUT_SECONDS")
    previous_idle_timeout_ms = System.get_env("EZTHROTTLE_IDLE_TIMEOUT_MS")
    System.put_env("EZTHROTTLE_IDLE_TIMEOUT_SECONDS", "1")
    System.delete_env("EZTHROTTLE_IDLE_TIMEOUT_MS")

    on_exit(fn ->
      if previous_idle_timeout_seconds do
        System.put_env("EZTHROTTLE_IDLE_TIMEOUT_SECONDS", previous_idle_timeout_seconds)
      else
        System.delete_env("EZTHROTTLE_IDLE_TIMEOUT_SECONDS")
      end

      if previous_idle_timeout_ms do
        System.put_env("EZTHROTTLE_IDLE_TIMEOUT_MS", previous_idle_timeout_ms)
      else
        System.delete_env("EZTHROTTLE_IDLE_TIMEOUT_MS")
      end
    end)

    :ok
  end

  test "idle account queue exits, then its url actor and registry entry are removed" do
    base_url = start_plug_server()
    table = :"idle_lifecycle_url_actors_#{System.unique_integer([:positive])}"

    {:ok, registry} =
      AccountQueueRegistry.start_link(
        name: :"idle_lifecycle_registry_#{System.unique_integer([:positive])}",
        table: table
      )

    on_exit(fn -> if Process.alive?(registry), do: Process.exit(registry, :kill) end)

    job = %Job{
      id: "idle-#{System.unique_integer([:positive])}",
      user_id: "tenant-idle",
      idempotent_key: "idle-key",
      url: "#{base_url}/work",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    :ok = GenServer.call(registry, {:enqueue, job, "enabled"})

    route_key = base_url
    [{^route_key, actor}] = :ets.lookup(table, route_key)

    queue =
      wait_until_value(fn ->
        actor
        |> :sys.get_state()
        |> Map.get(:queues)
        |> Map.values()
        |> List.first()
      end)

    queue_ref = Process.monitor(queue)
    actor_ref = Process.monitor(actor)

    assert Cluster.lookup_account_queue(route_key, Job.queue_key(job)) == queue

    assert_receive {:DOWN, ^queue_ref, :process, ^queue, :normal}, 3_000
    assert Cluster.lookup_account_queue(route_key, Job.queue_key(job)) == nil
    assert_receive {:DOWN, ^actor_ref, :process, ^actor, :normal}, 2_000

    assert wait_until(fn -> :ets.lookup(table, route_key) == [] end),
           "expected registry ETS entry to be removed after UrlActor shutdown"
  end

  defp start_plug_server do
    port = Enum.random(20_000..60_000)
    child_id = :"idle_lifecycle_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {OkPlug, []}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, deadline - System.monotonic_time(:millisecond))
    end
  end

  defp wait_until_value(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_value(fun, deadline)
  end

  defp do_wait_until_value(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for value")
        else
          Process.sleep(10)
          do_wait_until_value(fun, deadline)
        end

      value ->
        value
    end
  end
end
