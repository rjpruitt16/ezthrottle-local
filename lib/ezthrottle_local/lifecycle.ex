defmodule EzthrottleLocal.Lifecycle do
  @moduledoc """
  Graceful shutdown, mirroring Aquifer's lifecycle contract. On SIGTERM the
  BEAM runs init:stop, which calls EzthrottleLocal.Application.prep_stop/1
  before the supervision tree (and the HTTP endpoint) shut down. drain/0:

  1. marks the node draining: /ready returns 503 and new /jobs and /proxy
     requests are rejected with 503,
  2. keeps serving for EZTHROTTLE_SHUTDOWN_QUIESCE_MS so gateways notice,
  3. waits until this node's queued and in-flight work (including completion
     webhooks) has finished, bounded by EZTHROTTLE_SHUTDOWN_TIMEOUT_SECONDS,
  4. flushes the drain ledger once more when drain mode is enabled.

  Work still queued at the deadline stays in Mnesia for startup recovery.
  """
  require Logger

  alias EzthrottleLocal.{DrainFlush, IdempotentStore}

  @key {__MODULE__, :draining}
  @poll_ms 100

  def draining?, do: :persistent_term.get(@key, false)

  def begin_drain, do: :persistent_term.put(@key, true)

  @doc false
  def reset, do: :persistent_term.put(@key, false)

  def retry_after_seconds, do: 5

  def drain(opts \\ []) do
    timeout_ms =
      Keyword.get(opts, :timeout_ms, env_int("EZTHROTTLE_SHUTDOWN_TIMEOUT_SECONDS", 30) * 1_000)

    quiesce_ms = Keyword.get(opts, :quiesce_ms, env_int("EZTHROTTLE_SHUTDOWN_QUIESCE_MS", 500))
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    begin_drain()

    Logger.info(
      "[Lifecycle] draining: rejecting new work, waiting up to #{timeout_ms}ms for accepted work"
    )

    Process.sleep(min(quiesce_ms, timeout_ms))

    result = wait_for_work(deadline, false)

    if DrainFlush.enabled?() do
      DrainFlush.flush_all_batches("shutdown")
    end

    result
  end

  # Done only after two empty polls in a row. A finished job is marked
  # completed a moment before its webhook delivery job is inserted, so one
  # empty poll can land in that gap and stop the node with the webhook unsent.
  defp wait_for_work(deadline, empty_once?) do
    pending = IdempotentStore.pending_count()

    cond do
      pending == 0 and empty_once? ->
        Logger.info("[Lifecycle] accepted work finished")
        :drained

      pending == 0 ->
        Process.sleep(@poll_ms)
        wait_for_work(deadline, true)

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "[Lifecycle] shutdown deadline reached with #{pending} job(s) left for startup recovery"
        )

        {:timeout, pending}

      true ->
        Process.sleep(@poll_ms)
        wait_for_work(deadline, false)
    end
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end
end
