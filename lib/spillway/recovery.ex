# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.Recovery do
  @moduledoc """
  Puts jobs that were still queued when the node last stopped back on their
  queues, after the node has started.

  The jobs are read at boot, before the endpoint takes traffic, so the scan
  sees only rows from the previous run and doesn't compete with new writes.
  They're handed back to their queues here, in a task that runs alongside
  live traffic, instead of inside `Spillway.Application.start/2`.

  This used to happen inside `start/2`. With RocksDB storage the queued jobs
  survive restarts, and in soak run 3e there were tens of thousands of them.
  One call to a busy queue that took longer than its timeout then crashed
  `start/2` and the whole node, and the next boot had even more jobs to put
  back.
  """

  require Logger

  @retry_ms 1_000
  @log_every 10_000

  @doc "A child spec that puts `jobs` back on their queues in the background."
  def child_spec(jobs) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> run(jobs) end]},
      restart: :temporary
    }
  end

  @doc """
  Hands each job to `enqueue` in order. A call that exits (a queue too busy
  to answer within its timeout) is retried after a pause rather than
  dropped: these jobs were accepted, and nothing else will pick them up.
  """
  def run(jobs, enqueue \\ &Spillway.AccountQueueRegistry.enqueue/1, retry_ms \\ @retry_ms)

  def run([], _enqueue, _retry_ms), do: :ok

  def run(jobs, enqueue, retry_ms) do
    total = length(jobs)
    started = System.monotonic_time(:millisecond)
    Logger.info("recovering #{total} queued jobs in the background")

    jobs
    |> Enum.with_index(1)
    |> Enum.each(fn {job, n} ->
      put_back(job, enqueue, retry_ms)

      if rem(n, @log_every) == 0 and n < total,
        do: Logger.info("recovered #{n} of #{total} queued jobs")
    end)

    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("recovered #{total} queued jobs in #{elapsed} ms")
    :ok
  end

  defp put_back(job, enqueue, retry_ms) do
    enqueue.(job)
  catch
    :exit, reason ->
      Logger.warning(
        "recovering job #{job.id}: #{inspect(reason, limit: 5)}; retrying in #{retry_ms} ms"
      )

      Process.sleep(retry_ms)
      put_back(job, enqueue, retry_ms)
  end
end
