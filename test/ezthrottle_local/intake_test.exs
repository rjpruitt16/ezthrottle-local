defmodule EzthrottleLocal.IntakeTest do
  @moduledoc """
  The standalone caller-side submission path (EzthrottleLocal.Intake):
  concurrent submissions must respect fair admission and the per-user limit
  exactly, and a queue retiring while jobs arrive must not lose any.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.{AccountQueue, AccountQueueRegistry, Job, UrlActor}

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts
    def call(%{request_path: "/.well-known/l8"} = conn, _), do: send_resp(conn, 404, "")

    def call(conn, opts) do
      if conn.request_path == "/work", do: send(Keyword.fetch!(opts, :test_pid), :hit)

      conn
      |> put_resp_header("x-aqueduct-max-concurrent", "64")
      |> send_resp(200, "ok")
    end
  end

  defp job(id, user, base) do
    %Job{
      id: id,
      user_id: user,
      idempotent_key: "key-#{id}",
      url: "#{base}/work",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  defp concurrently(n, fun) do
    1..n |> Enum.map(fn i -> Task.async(fn -> fun.(i) end) end) |> Task.await_many(10_000)
  end

  setup do
    on_exit(fn ->
      for k <-
            ~w(EZTHROTTLE_MAX_PENDING_PER_UPSTREAM EZTHROTTLE_MAX_PENDING_PER_USER EZTHROTTLE_IDLE_TIMEOUT_MS),
          do: System.delete_env(k)
    end)
  end

  test "concurrent submissions never admit past the shared backlog limit" do
    System.put_env("EZTHROTTLE_MAX_PENDING_PER_UPSTREAM", "20")
    stamp = System.unique_integer([:positive])
    base = "http://fair-#{stamp}.example"
    actor = AccountQueueRegistry.actor_for(job("fair-#{stamp}-0", "u", base))
    UrlActor.update_max_concurrent(actor, 0)

    results =
      concurrently(100, fn i ->
        AccountQueueRegistry.submit(job("fair-#{stamp}-#{i}", "u#{rem(i, 10)}", base))
      end)

    accepted = Enum.count(results, &match?({:accepted, _}, &1))
    rejected = Enum.count(results, &match?({:rejected, _, _, _}, &1))

    assert accepted <= 20
    assert accepted > 0
    assert accepted + rejected == 100

    queue = :sys.get_state(actor).queues.shared
    assert {:ok, ^accepted} = AccountQueue.local_backlog(queue)
  end

  test "concurrent submissions from one user stop exactly at the per-user limit" do
    System.put_env("EZTHROTTLE_MAX_PENDING_PER_USER", "5")
    stamp = System.unique_integer([:positive])
    base = "http://peruser-#{stamp}.example"
    actor = AccountQueueRegistry.actor_for(job("peruser-#{stamp}-0", "noisy", base))
    UrlActor.update_max_concurrent(actor, 0)

    results =
      concurrently(50, fn i ->
        AccountQueueRegistry.submit(job("peruser-#{stamp}-#{i}", "noisy", base))
      end)

    assert Enum.count(results, &match?({:accepted, _}, &1)) == 5

    assert Enum.all?(
             results -- Enum.filter(results, &match?({:accepted, _}, &1)),
             &match?({:rejected, "user_queue", 5, _}, &1)
           )

    # Internal work (webhook deliveries) bypasses the per-user limit.
    assert {:accepted, _} =
             AccountQueueRegistry.submit_internal(job("peruser-#{stamp}-internal", "noisy", base))
  end

  test "jobs arriving while their queue retires after going idle are never lost" do
    System.put_env("EZTHROTTLE_IDLE_TIMEOUT_MS", "200")
    previous = Application.get_env(:ezthrottle_local, :default_rps)
    Application.put_env(:ezthrottle_local, :default_rps, 100_000.0)
    on_exit(fn -> Application.put_env(:ezthrottle_local, :default_rps, previous || 2.0) end)

    port = Enum.random(20_000..60_000)

    start_supervised!(
      {Bandit, plug: {Upstream, test_pid: self()}, port: port, startup_log: false}
    )

    base = "http://127.0.0.1:#{port}"
    stamp = System.unique_integer([:positive])

    rounds = 8
    per_round = 25

    actors =
      for round <- 1..rounds do
        results =
          concurrently(per_round, fn i ->
            AccountQueueRegistry.submit(job("idle-#{stamp}-#{round}-#{i}", "u#{rem(i, 3)}", base))
          end)

        assert Enum.all?(results, &match?({:accepted, _}, &1))
        actor = AccountQueueRegistry.actor_for(job("probe-#{stamp}-#{round}", "u", base))
        # Land the next burst around the moment the queue retires.
        Process.sleep(Enum.at([180, 200, 220, 240, 210], rem(round, 5)))
        actor
      end

    # The domain's actor (and so its queues) retired between some rounds;
    # otherwise this test wouldn't be exercising retirement at all.
    assert length(Enum.uniq(actors)) > 1

    for _ <- 1..(rounds * per_round), do: assert_receive(:hit, 10_000)
  end
end
