defmodule EzthrottleLocal.NodeIdle do
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

  # Some tests hold jobs on purpose by setting a queue's max_concurrent to 0
  # (only tests do that); such a queue never drains, so stop it.
  defp release_held_queues do
    for pid <- Process.list(),
        match?({:dictionary, d} when is_list(d), Process.info(pid, :dictionary)),
        {:dictionary, d} = Process.info(pid, :dictionary),
        d[:"$initial_call"] == {EzthrottleLocal.AccountQueue, :init, 1},
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
    EzthrottleLocal.IdempotentStore.pending_count() == 0 and queue_backlog() == 0
  end

  # Rows keyed by a queue pid are that queue's backlog; {pid, user} rows are per-user.
  defp queue_backlog do
    :ets.select(:ez_queue_backlog, [{{:"$1", :"$2"}, [{:is_pid, :"$1"}], [:"$2"]}]) |> Enum.sum()
  rescue
    ArgumentError -> 0
  end
end
