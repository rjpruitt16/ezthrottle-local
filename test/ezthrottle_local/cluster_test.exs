defmodule EzthrottleLocal.ClusterTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.Cluster
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Job
  alias EzthrottleLocal.UrlActor

  defmodule OkPlug do
    import Plug.Conn

    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, "ok")
  end

  setup do
    previous_limit = System.get_env("EZTHROTTLE_MAX_PENDING_PER_USER")
    previous_query = Application.get_env(:ezthrottle_local, :dns_cluster_query)

    on_exit(fn ->
      restore_env("EZTHROTTLE_MAX_PENDING_PER_USER", previous_limit)

      if previous_query do
        Application.put_env(:ezthrottle_local, :dns_cluster_query, previous_query)
      else
        Application.delete_env(:ezthrottle_local, :dns_cluster_query)
      end
    end)

    :ok
  end

  test "concurrent url actors converge on one Syn-owned account queue" do
    stamp = System.unique_integer([:positive])
    domain = "http://cluster-#{stamp}.example"
    actor_a = start_actor(domain, "#{domain}/a")
    actor_b = start_actor(domain, "#{domain}/b")

    UrlActor.update_max_concurrent(actor_a, 0)
    UrlActor.update_max_concurrent(actor_b, 0)

    job_a = job("cluster-a-#{stamp}", "same-user", domain)

    job_b = %{
      job("cluster-b-#{stamp}", "same-user", domain)
      | idempotent_key: job_a.idempotent_key
    }

    results =
      [
        Task.async(fn -> UrlActor.submit(actor_a, job_a) end),
        Task.async(fn -> UrlActor.submit(actor_b, job_b) end)
      ]
      |> Task.await_many(5_000)

    assert [{:accepted, accepted_job}] = Enum.filter(results, &match?({:accepted, _job}, &1))
    assert [{:duplicate, duplicate_id}] = Enum.filter(results, &match?({:duplicate, _id}, &1))
    assert duplicate_id == accepted_job.id

    queue_a = :sys.get_state(actor_a).queues.shared
    queue_b = :sys.get_state(actor_b).queues.shared

    assert queue_a == queue_b
    assert Cluster.lookup_account_queue(domain, :shared) == queue_a
    assert Cluster.lookup_job_store(accepted_job.id) == Process.whereis(IdempotentStore)

    IdempotentStore.delete_job(accepted_job)
    assert Cluster.lookup_job_store(accepted_job.id) == nil
  end

  test "per-user ceiling rejects only that user and internal work bypasses it" do
    System.put_env("EZTHROTTLE_MAX_PENDING_PER_USER", "1")
    stamp = System.unique_integer([:positive])
    upstream = "http://limit-#{stamp}.example"

    queue =
      start_supervised!(
        Supervisor.child_spec(
          {AccountQueue, queue_key: :shared, upstream: upstream, max_concurrent: 0, rps: 100.0},
          id: {:account_queue_limit, stamp}
        )
      )

    first = job("limit-first-#{stamp}", "noisy", upstream)
    rejected = job("limit-rejected-#{stamp}", "noisy", upstream)
    quiet = job("limit-quiet-#{stamp}", "quiet", upstream)
    internal = job("limit-internal-#{stamp}", "noisy", upstream)

    assert {:accepted, ^first} = AccountQueue.submit(queue, first)
    assert {:rejected, "user_queue", 1, 1} = AccountQueue.submit(queue, rejected)
    assert IdempotentStore.get_job(rejected.id) == nil
    assert {:accepted, ^quiet} = AccountQueue.submit(queue, quiet)
    assert {:accepted, ^internal} = AccountQueue.submit_internal(queue, internal)

    state = :sys.get_state(queue)
    assert state.pending_by_user == %{"noisy" => 2, "quiet" => 1}

    Enum.each([first, quiet, internal], &IdempotentStore.delete_job/1)
  end

  test "DNS discovery is optional and builds a libcluster topology when configured" do
    Application.delete_env(:ezthrottle_local, :dns_cluster_query)
    assert Cluster.topologies() == []

    Application.put_env(:ezthrottle_local, :dns_cluster_query, "ezthrottle.internal")

    assert [ezthrottle_dns: topology] = Cluster.topologies()
    assert topology[:strategy] == Elixir.Cluster.Strategy.DNSPoll
    assert topology[:config][:query] == "ezthrottle.internal"
  end

  test "a completed job releases its user's pending slot" do
    System.put_env("EZTHROTTLE_MAX_PENDING_PER_USER", "1")
    stamp = System.unique_integer([:positive])
    upstream = start_plug_server(stamp)

    queue =
      start_supervised!(
        Supervisor.child_spec(
          {AccountQueue, queue_key: :shared, upstream: upstream, max_concurrent: 1, rps: 100.0},
          id: {:account_queue_release, stamp}
        )
      )

    first = job("release-first-#{stamp}", "one-at-a-time", upstream)
    second = job("release-second-#{stamp}", "one-at-a-time", upstream)

    assert {:accepted, ^first} = AccountQueue.submit(queue, first)
    assert wait_until(fn -> IdempotentStore.get_status(first.id) == "completed" end)
    assert {:accepted, ^second} = AccountQueue.submit(queue, second)
    assert wait_until(fn -> IdempotentStore.get_status(second.id) == "completed" end)

    IdempotentStore.delete_job(first)
    IdempotentStore.delete_job(second)
  end

  defp start_actor(domain, url_key) do
    stamp = System.unique_integer([:positive])

    start_supervised!(
      Supervisor.child_spec(
        {UrlActor, url_key: url_key, domain: domain},
        id: {:cluster_url_actor, stamp}
      )
    )
  end

  defp job(id, user_id, upstream) do
    %Job{
      id: id,
      user_id: user_id,
      idempotent_key: "key-#{id}",
      url: upstream <> "/work",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  defp start_plug_server(stamp) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: {OkPlug, []}, port: port},
        id: {:cluster_test_server, stamp}
      )
    )

    "http://127.0.0.1:#{port}"
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10) && do_wait_until(fun, deadline)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
