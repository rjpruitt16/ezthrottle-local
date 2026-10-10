defmodule EzthrottleLocal.MultinodeFixesTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.{AccountQueue, Cluster, RemoteBacklog, SynEventHandler}

  describe "SynEventHandler.resolve_registry_conflict/4" do
    test "keeps the later registration, as Syn's default does, without killing the other" do
      older = spawn(fn -> Process.sleep(:infinity) end)
      newer = spawn(fn -> Process.sleep(:infinity) end)

      assert SynEventHandler.resolve_registry_conflict(
               :scope,
               :name,
               {older, nil, 1},
               {newer, nil, 2}
             ) ==
               newer

      assert SynEventHandler.resolve_registry_conflict(
               :scope,
               :name,
               {newer, nil, 2},
               {older, nil, 1}
             ) ==
               newer

      assert Process.alive?(older)
    end

    test "breaks a timestamp tie the same way on every node" do
      a = spawn(fn -> Process.sleep(:infinity) end)
      b = spawn(fn -> Process.sleep(:infinity) end)

      assert SynEventHandler.resolve_registry_conflict(:s, :n, {a, nil, 5}, {b, nil, 5}) ==
               SynEventHandler.resolve_registry_conflict(:s, :n, {b, nil, 5}, {a, nil, 5})
    end

    test "is the handler Syn is configured with" do
      assert Application.get_env(:syn, :event_handler) == SynEventHandler
    end
  end

  describe "AccountQueue.local_backlogs/0" do
    test "returns queue backlogs only, not per-user rows, never negative" do
      queue = spawn(fn -> Process.sleep(:infinity) end)
      drifted = spawn(fn -> Process.sleep(:infinity) end)
      :ets.insert(:ez_queue_backlog, [{queue, 3}, {{queue, "user-1"}, 2}, {drifted, -1}])

      on_exit(fn ->
        for key <- [queue, {queue, "user-1"}, drifted], do: :ets.delete(:ez_queue_backlog, key)
      end)

      backlogs = AccountQueue.local_backlogs()
      assert {queue, 3} in backlogs
      assert {drifted, 0} in backlogs
      refute Enum.any?(backlogs, fn {key, _} -> is_tuple(key) end)
    end
  end

  test "a refresh against an unreachable node leaves the caller running" do
    caller = self()

    pid =
      spawn(fn ->
        RemoteBacklog.refresh([:"ghost@127.0.0.1", :"other-ghost@127.0.0.1"])
        send(caller, :refreshed)
      end)

    ref = Process.monitor(pid)
    assert_receive :refreshed, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "RemoteBacklog reports queues it hasn't seen as unknown" do
    assert RemoteBacklog.lookup(self()) == :unknown
  end

  test "a standalone node has no cluster names to release when it drains" do
    assert Cluster.release_local_queues() == 0
  end
end
