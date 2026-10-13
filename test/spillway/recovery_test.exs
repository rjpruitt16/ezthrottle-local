# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.RecoveryTest do
  @moduledoc """
  Queued jobs from the previous run go back on their queues in the
  background. In soak run 3e this ran inside Application.start/2, and one
  queue call that timed out under load took the whole node down.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Spillway.Recovery

  defp jobs(n), do: for(i <- 1..n, do: %Spillway.Job{id: "recovery-#{i}"})

  test "a queue call that times out is retried, not dropped, and doesn't crash" do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> %{} end)

    # The second job's queue is too busy to answer the first two times.
    enqueue = fn job ->
      n =
        Agent.get_and_update(
          attempts,
          &{Map.get(&1, job.id, 0) + 1, Map.update(&1, job.id, 1, fn c -> c + 1 end)}
        )

      if job.id == "recovery-2" and n <= 2,
        do: exit({:timeout, {GenServer, :call, [:queue, {:enqueue, job}, 5_000]}}),
        else: send(test_pid, {:enqueued, job.id})
    end

    log = capture_log(fn -> assert :ok = Recovery.run(jobs(3), enqueue, 1) end)

    assert_received {:enqueued, "recovery-1"}
    assert_received {:enqueued, "recovery-2"}
    assert_received {:enqueued, "recovery-3"}
    refute_received {:enqueued, _}
    assert Agent.get(attempts, & &1["recovery-2"]) == 3
    assert log =~ "retrying"
  end

  test "it runs as a temporary task, so start-up doesn't wait for it" do
    test_pid = self()
    gate = make_ref()

    spec = Recovery.child_spec(jobs(2))
    assert spec.restart == :temporary

    # A queue that blocks: starting the child must still return at once.
    {Task, :start_link, [_]} = spec.start

    {:ok, pid} =
      Task.start_link(fn ->
        Recovery.run(jobs(2), fn job ->
          send(test_pid, {:started, job.id})
          receive do: (^gate -> :ok)
        end)
      end)

    assert_receive {:started, "recovery-1"}
    assert Process.alive?(pid)
    send(pid, gate)
    assert_receive {:started, "recovery-2"}
    send(pid, gate)
  end
end
