defmodule EzthrottleLocal.ParallelIntakeTest do
  @moduledoc """
  The standalone submit path persists in the caller, reads queue backlog from
  a shared table instead of calling every queue, and upgrades job records
  written by older versions.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.{AccountQueue, AccountQueueRegistry, IdempotentStore, Job, UrlActor}

  defp job(id, user, domain) do
    %Job{
      id: id,
      user_id: user,
      idempotent_key: "key-#{id}",
      url: "#{domain}/work",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  test "the backlog table matches each queue's own snapshot" do
    stamp = System.unique_integer([:positive])
    domain = "http://intake-#{stamp}.example"
    first = job("intake-#{stamp}-0", "u", domain)
    actor = AccountQueueRegistry.actor_for(first)
    # Hold dispatch so submissions stay queued.
    UrlActor.update_max_concurrent(actor, 0)

    for i <- 0..4 do
      assert {:accepted, _} =
               AccountQueueRegistry.submit(job("intake-#{stamp}-#{i}", "u#{i}", domain))
    end

    queue = :sys.get_state(actor).queues.shared
    assert {:ok, 5} = AccountQueue.local_backlog(queue)
    assert %{backlog: 5} = AccountQueue.snapshot(queue)

    # A duplicate persists nothing and queues nothing.
    assert {:duplicate, _} =
             AccountQueueRegistry.submit(%{
               job("other-#{stamp}", "u0", domain)
               | idempotent_key: first.idempotent_key
             })

    assert {:ok, 5} = AccountQueue.local_backlog(queue)
  end

  test "a job record written before execute_before existed is upgraded on read" do
    stamp = System.unique_integer([:positive])
    current = job("old-#{stamp}", "u", "http://old-#{stamp}.example")
    :ok = IdempotentStore.check_or_insert(current)

    # Rewrite the stored struct without the newer field, as an older version would have.
    old = current |> Map.delete(:execute_before)

    :mnesia.dirty_write(
      {:jobs, current.id, old, System.system_time(:millisecond) + 60_000, :queued}
    )

    upgraded = IdempotentStore.get_job(current.id)
    assert %Job{execute_before: nil} = upgraded
    refute Job.execution_expired?(upgraded)

    assert Enum.any?(
             IdempotentStore.recoverable_jobs(),
             &(&1.id == current.id and Map.has_key?(&1, :execute_before))
           )
  end

  test "the key gate lets exactly one of many concurrent inserts for a key win" do
    stamp = System.unique_integer([:positive])
    base = job("gate-#{stamp}", "u", "http://gate-#{stamp}.example")

    results =
      1..50
      |> Enum.map(fn i ->
        Task.async(fn -> IdempotentStore.check_or_insert(%{base | id: "gate-#{stamp}-#{i}"}) end)
      end)
      |> Task.await_many(5_000)

    assert [:ok] = Enum.filter(results, &(&1 == :ok))
    winner = Enum.find_index(results, &(&1 == :ok)) + 1
    assert Enum.all?(results -- [:ok], &(&1 == {:duplicate, "gate-#{stamp}-#{winner}"}))
  end

  test "a key can be claimed again after its job is deleted or the ledger is cleared" do
    stamp = System.unique_integer([:positive])
    first = job("again-#{stamp}-1", "u", "http://again-#{stamp}.example")
    assert :ok = IdempotentStore.check_or_insert(first)
    assert {:duplicate, _} = IdempotentStore.check_or_insert(%{first | id: "again-#{stamp}-2"})

    IdempotentStore.delete_job(first)
    assert :ok = IdempotentStore.check_or_insert(%{first | id: "again-#{stamp}-3"})

    IdempotentStore.clear_ledger()
    assert :ok = IdempotentStore.check_or_insert(%{first | id: "again-#{stamp}-4"})
  end
end
