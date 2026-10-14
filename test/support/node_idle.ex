# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.NodeIdle do
  @moduledoc """
  Waits for the node to have no work left: nothing pending in the store and
  no backlog in any account queue. Tests that measure node-wide state (a
  graceful drain, "is this instance shared") need that, because earlier
  tests can leave jobs retrying against unreachable hosts in memory, and a
  retry writes its job back to the store even after the store was cleared.
  """

  def wait(timeout_ms \\ 30_000) do
    release_held_queues()
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline)
  end

  @doc """
  Stops every account queue and every request it has in flight, then clears
  the store. For tests that measure node-wide state from a clean start.

  wait/1 can't see a job sitting out a retry delay after the store was
  cleared: its row is gone and it isn't in any queue's backlog. When the
  delay ends it fails again and writes itself back as queued (record_retry),
  so a drain that started "idle" waits on it. user_load_test leaves webhook
  deliveries retrying against a server it has stopped, and the lifecycle
  drain test failed on them.
  """
  def reset do
    pids =
      for pid <- Process.list(),
          queue_process?(pid),
          do: pid

    Enum.each(pids, &Process.exit(&1, :kill))
    Enum.each(pids, &wait_dead/1)

    try do
      :ets.delete_all_objects(:ez_queue_backlog)
    rescue
      ArgumentError -> :ok
    end

    Spillway.IdempotentStore.clear_ledger()
    :ok
  end

  # An account queue, or a request worker it spawned (a spawned fun's
  # initial call names the module that defined it).
  defp queue_process?(pid) do
    case Process.info(pid, [:dictionary, :initial_call]) do
      [{:dictionary, d}, {:initial_call, {mod, _, _}}] ->
        d[:"$initial_call"] == {Spillway.AccountQueue, :init, 1} or mod == Spillway.AccountQueue

      _ ->
        false
    end
  end

  defp wait_dead(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      1_000 -> :ok
    end
  end

  # Some tests hold jobs on purpose by setting a queue's max_concurrent to 0
  # (only tests do that); such a queue never drains, so stop it.
  defp release_held_queues do
    for pid <- Process.list(),
        match?({:dictionary, d} when is_list(d), Process.info(pid, :dictionary)),
        {:dictionary, d} = Process.info(pid, :dictionary),
        d[:"$initial_call"] == {Spillway.AccountQueue, :init, 1},
        held?(pid) do
      Process.exit(pid, :kill)
      :ets.delete(:ez_queue_backlog, pid)
      :ets.match_delete(:ez_queue_backlog, {{pid, :_}, :_})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp held?(pid) do
    :sys.get_state(pid, 1_000).max_concurrent == 0
  catch
    _, _ -> false
  end

  defp do_wait(deadline) do
    cond do
      idle?() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(100) && do_wait(deadline)
    end
  end

  defp idle? do
    Spillway.IdempotentStore.pending_count() == 0 and queue_backlog() == 0
  end

  # Rows keyed by a queue pid are that queue's backlog; {pid, user} rows are per-user.
  defp queue_backlog do
    :ets.select(:ez_queue_backlog, [{{:"$1", :"$2"}, [{:is_pid, :"$1"}], [:"$2"]}]) |> Enum.sum()
  rescue
    ArgumentError -> 0
  end
end
