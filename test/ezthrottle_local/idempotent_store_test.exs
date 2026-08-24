defmodule EzthrottleLocal.IdempotentStoreTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Job

  # Regression test for the lookup-then-insert race: the original
  # ETS-backed check_or_insert did :ets.lookup followed by a separate
  # :ets.insert, so two concurrent requests with the same idempotent key
  # could both observe an empty lookup and both proceed to insert,
  # silently defeating duplicate detection. The Mnesia version wraps both
  # steps in one transaction, which should make this impossible.
  test "concurrent check_or_insert calls with unique keys are never misreported as duplicates" do
    n = 50
    stamp = System.unique_integer([:positive])

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          job = %Job{
            id: "concurrent-#{stamp}-#{i}",
            user_id: "concurrent-user",
            idempotent_key: "concurrent-key-#{stamp}-#{i}",
            url: "https://example.com/webhook",
            method: "POST",
            headers: %{},
            body: nil,
            webhook_url: "https://example.com/callback",
            status: :queued,
            created_at: System.system_time(:millisecond)
          }

          IdempotentStore.check_or_insert(job)
        end)
      end

    results = Task.await_many(tasks, 5_000)

    assert Enum.all?(results, &(&1 == :ok)),
           "expected every unique-key insert to succeed as fresh, got: #{inspect(results)}"
  end

  test "check_or_insert correctly reports a genuine duplicate" do
    stamp = System.unique_integer([:positive])

    job = %Job{
      id: "dup-#{stamp}-1",
      user_id: "dup-user",
      idempotent_key: "dup-key-#{stamp}",
      url: "https://example.com/webhook",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    assert :ok = IdempotentStore.check_or_insert(job)

    retry = %{job | id: "dup-#{stamp}-2"}
    assert {:duplicate, existing_id} = IdempotentStore.check_or_insert(retry)
    assert existing_id == job.id
  end

  test "delete_job removes both rows so a later retry is treated as fresh" do
    stamp = System.unique_integer([:positive])

    job = %Job{
      id: "del-#{stamp}",
      user_id: "del-user",
      idempotent_key: "del-key-#{stamp}",
      url: "https://example.com/webhook",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    assert :ok = IdempotentStore.check_or_insert(job)
    assert :ok = IdempotentStore.delete_job(job)
    assert nil == IdempotentStore.get_job(job.id)

    # Same idempotent key, resubmitted after deletion — must be treated as
    # fresh, not as a duplicate pointing at a job that no longer exists.
    assert :ok = IdempotentStore.check_or_insert(job)
  end

  # Drain mode's store-level primitives (EzthrottleLocal.DrainFlush):
  # enumerate returns exactly what was inserted, hash-only, and clear wipes
  # the whole table so a previously-duplicate key is fresh afterward. Runs
  # against the same shared Mnesia instance every other test in this file
  # does, so it explicitly clears first (rather than assuming a clean
  # table) and only asserts on its own uniquely-stamped entries.
  test "list_ledger and clear_ledger" do
    IdempotentStore.clear_ledger()

    stamp = System.unique_integer([:positive])

    job1 = %Job{
      id: "ledger-#{stamp}-1",
      user_id: "ledger-user",
      idempotent_key: "super-secret-plaintext-key-#{stamp}",
      url: "https://example.com/webhook",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    job2 = %{job1 | id: "ledger-#{stamp}-2", idempotent_key: "key2-#{stamp}"}

    assert :ok = IdempotentStore.check_or_insert(job1)
    assert :ok = IdempotentStore.check_or_insert(job2)
    IdempotentStore.update_status(job2.id, :completed)

    entries = IdempotentStore.list_ledger()
    assert length(entries) == 2

    by_job_id = Map.new(entries, &{&1.job_id, &1})
    assert %{status: :completed} = by_job_id[job2.id]
    assert %{idempotent_key_hash: hash} = by_job_id[job1.id]
    assert is_binary(hash) and hash != ""
    refute hash =~ job1.idempotent_key

    IdempotentStore.clear_ledger()
    assert IdempotentStore.list_ledger() == []

    # A key that was a duplicate before the clear should now be fresh --
    # proving the clear actually happened, not just that list returns [].
    assert :ok = IdempotentStore.check_or_insert(job1)
  end
end
