defmodule EzthrottleLocal.SynEventHandler do
  @moduledoc """
  Resolves Syn registry conflicts without killing the losing process.

  After a netsplit heals, a name registered on both sides of the split (an
  account queue for the same user and upstream) has two processes. Syn's
  default keeps the more recently registered one and kills the other with
  `{:syn_resolve_kill, ...}`. A killed account queue loses the jobs it held
  in memory, while their Mnesia rows stay `:queued` with nothing left to
  dispatch them.

  This handler picks the same winner Syn would (later registration, pid as
  tiebreaker, so both nodes agree) but returns it instead of letting Syn
  kill the other. The loser just loses the name: new jobs go to the winner,
  and the loser keeps dispatching the jobs it already holds, then retires
  when idle like any other queue. Two queues briefly serve the same user,
  so that user's per-queue pacing is looser for that window; no job is lost.
  """
  @behaviour :syn_event_handler

  @impl true
  def resolve_registry_conflict(_scope, _name, {pid1, _meta1, time1}, {pid2, _meta2, time2}) do
    cond do
      time1 > time2 -> pid1
      time1 < time2 -> pid2
      true -> max(pid1, pid2)
    end
  end
end
