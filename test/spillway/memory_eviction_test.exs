# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.MemoryEvictionTest do
  use ExUnit.Case, async: false

  alias Spillway.IdempotentStore
  alias Spillway.Job

  setup do
    IdempotentStore.clear_ledger()
    prev = System.get_env("SPILLWAY_MEMORY_LIMIT_MB")
    System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")

    on_exit(fn ->
      if prev,
        do: System.put_env("SPILLWAY_MEMORY_LIMIT_MB", prev),
        else: System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")

      IdempotentStore.clear_ledger()
    end)
  end

  defp insert(name) do
    job = %Job{
      id: "evict-#{name}-#{System.unique_integer([:positive])}",
      user_id: "evict-user",
      idempotent_key: "evict-key-#{name}",
      url: "https://example.com/work",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    :ok = IdempotentStore.check_or_insert(job)
    job
  end

  defp complete(job) do
    IdempotentStore.put_result(job.id, %{"status" => 200}, :completed)
    IdempotentStore.update_status(job.id, :completed)
  end

  test "evicts the oldest finished job with its result, delivery mode and key; never a queued one" do
    oldest = insert("oldest")
    complete(oldest)
    IdempotentStore.set_delivery_mode(oldest.id, :stream)
    Process.sleep(5)
    newer = insert("newer")
    complete(newer)
    queued = insert("queued")

    assert IdempotentStore.evict_finished(1) == 1

    assert IdempotentStore.get_job(oldest.id) == nil
    assert IdempotentStore.get_result(oldest.id) == nil
    assert IdempotentStore.get_delivery_mode(oldest.id) == :webhook
    assert IdempotentStore.get_job(newer.id)
    assert IdempotentStore.get_job(queued.id)
    assert IdempotentStore.counts() == %{total_jobs: 2, queue_depth: 1}

    # The evicted job's idempotency key is free again.
    again = %{insert_job_like(oldest) | id: "evict-again-#{System.unique_integer([:positive])}"}
    assert IdempotentStore.check_or_insert(again) == :ok

    # Asking for more than there are evicts only finished jobs.
    assert IdempotentStore.evict_finished(10) == 1
    assert IdempotentStore.get_job(queued.id)
  end

  test "memory budget is off without SPILLWAY_MEMORY_LIMIT_MB and evicts once past it" do
    done = insert("budget-done")
    complete(done)
    queued = insert("budget-queued")

    assert IdempotentStore.enforce_memory_budget() == 0
    assert IdempotentStore.get_job(done.id)

    # Any running VM is past 70% of 1 MB.
    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", "1")
    assert IdempotentStore.enforce_memory_budget() == 1
    assert IdempotentStore.get_job(done.id) == nil
    assert IdempotentStore.get_job(queued.id)
  end

  test "a job refused before it was queued is discarded and its key freed" do
    refused = insert("refused")
    assert IdempotentStore.counts() == %{total_jobs: 1, queue_depth: 1}

    assert IdempotentStore.discard_refused(refused) == :ok
    assert IdempotentStore.get_job(refused.id) == nil
    assert IdempotentStore.counts() == %{total_jobs: 0, queue_depth: 0}

    # Discarding twice (the controller and the registry both clean up) is harmless.
    assert IdempotentStore.discard_refused(refused) == :ok
    assert IdempotentStore.counts() == %{total_jobs: 0, queue_depth: 0}

    retry = %{
      insert_job_like(refused)
      | id: "refused-retry-#{System.unique_integer([:positive])}"
    }

    assert IdempotentStore.check_or_insert(retry) == :ok

    # A key a newer job now holds is left alone.
    assert IdempotentStore.discard_refused(refused) == :ok
    assert {:duplicate, id} = IdempotentStore.check_or_insert(%{retry | id: "third"})
    assert id == retry.id
  end

  defp insert_job_like(job), do: %{job | status: :queued}
end
