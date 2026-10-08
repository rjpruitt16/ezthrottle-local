defmodule EzthrottleLocal.PipelinePerfTest do
  @moduledoc """
  Performance benchmarks: run with `make perf`, excluded from `mix test`.
  They mirror Aquifer's perf_test.go and measure EZThrottle's own overhead
  (storage writes, queueing, dispatch, webhooks) against a local upstream
  and webhook receiver that answer instantly and allow a very high rate.
  Compare numbers on the same machine only.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Job

  @moduletag :perf
  @jobs 200
  @throughput_jobs 2000
  @retained 100_000
  @callers 8

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    # Skip the L8 metadata probe so only real requests are counted.
    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")

    def call(conn, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {Keyword.fetch!(opts, :kind), System.monotonic_time(:microsecond)}
      )

      conn
      |> put_resp_header("x-aqueduct-rps", "100000")
      |> put_resp_header("x-aqueduct-max-concurrent", "64")
      |> send_resp(200, "ok")
    end
  end

  setup do
    previous = Application.get_env(:ezthrottle_local, :default_rps)
    Application.put_env(:ezthrottle_local, :default_rps, 100_000.0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezthrottle_local, :default_rps, previous),
        else: Application.delete_env(:ezthrottle_local, :default_rps)
    end)

    {:ok, upstream: start_server(:upstream), webhook: start_server(:webhook)}
  end

  defp start_server(kind) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: {Upstream, test_pid: self(), kind: kind}, port: port},
        id: {:perf, kind}
      )
    )

    "http://127.0.0.1:#{port}"
  end

  defp submit(ctx, key) do
    {:ok, job} =
      Job.new(%{
        "user_id" => "perf",
        "idempotent_key" => key,
        "url" => ctx.upstream <> "/work",
        "method" => "POST",
        "webhook_url" => ctx.webhook <> "/hook"
      })

    {:accepted, _} = AccountQueueRegistry.submit(job)
  end

  # Sends one job at a time and splits its trip into accept (validated and
  # stored, i.e. POST /jobs returns), queue (accepted until the upstream
  # receives it) and total.
  test "job latency", ctx do
    stamp = System.unique_integer([:positive])

    timings =
      for i <- 1..@jobs do
        started = System.monotonic_time(:microsecond)
        submit(ctx, "lat-#{stamp}-#{i}")
        accepted = System.monotonic_time(:microsecond)
        assert_receive {:upstream, arrived}, 10_000
        {accepted - started, arrived - accepted}
      end

    accept = avg_ms(Enum.map(timings, &elem(&1, 0)))
    queue = avg_ms(Enum.map(timings, &elem(&1, 1)))

    IO.puts(
      "\nJobLatency: accept #{fmt(accept)} ms/op  queue #{fmt(queue)} ms/op  total #{fmt(accept + queue)} ms/op  (#{@jobs} jobs)"
    )
  end

  # Many concurrent callers submit jobs; reports how many per second make it
  # all the way through: accepted, dispatched, completed, webhook delivered.
  # Run on an empty store, then with 100k finished jobs retained (completed
  # jobs are kept for 30 minutes, so a busy node always carries many).
  test "pipeline throughput", ctx do
    throughput(ctx, "empty store")
    retain(@retained)
    throughput(ctx, "#{div(@retained, 1000)}k retained jobs")
  after
    EzthrottleLocal.IdempotentStore.clear_ledger()
  end

  defp throughput(ctx, label) do
    stamp = System.unique_integer([:positive])
    started = System.monotonic_time(:microsecond)

    1..@throughput_jobs
    |> Task.async_stream(&submit(ctx, "tp-#{stamp}-#{&1}"),
      max_concurrency: @callers,
      ordered: false
    )
    |> Stream.run()

    for _ <- 1..@throughput_jobs, do: assert_receive({:webhook, _}, 60_000)
    elapsed = System.monotonic_time(:microsecond) - started
    flush_mailbox()

    IO.puts(
      "\nPipelineThroughput (#{label}): #{fmt(@throughput_jobs / (elapsed / 1_000_000))} jobs/s  (#{@throughput_jobs} jobs, #{@callers} callers)"
    )
  end

  defp retain(n) do
    expires = System.system_time(:millisecond) + 30 * 60 * 1000

    {:ok, job} =
      Job.new(%{
        "user_id" => "retained",
        "idempotent_key" => "k",
        "url" => "http://example.com",
        "method" => "POST",
        "webhook_url" => "http://example.com/hook"
      })

    for i <- 1..n,
        do:
          :mnesia.dirty_write(
            {:jobs, "retained-#{i}", %{job | id: "retained-#{i}"}, expires, :completed}
          )

    EzthrottleLocal.IdempotentStore.seed_counts()
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp avg_ms(us), do: Enum.sum(us) / length(us) / 1000
  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
