# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.StoreExpiryTest do
  use ExUnit.Case, async: false

  alias Spillway.IdempotentStore
  alias Spillway.Job

  setup do
    IdempotentStore.clear_ledger()
    on_exit(fn -> IdempotentStore.clear_ledger() end)
  end

  defp insert(name) do
    job = %Job{
      id: "expiry-#{name}-#{System.unique_integer([:positive])}",
      user_id: "expiry-user",
      idempotent_key: "expiry-key-#{name}",
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

  test "cleanup deletes expired jobs through the expiry index, in batches" do
    jobs = for i <- 1..25, do: insert("expire-#{i}")
    Enum.each(jobs, &complete/1)
    queued = insert("expire-queued")

    # 31 minutes from now: past completed retention, not queued retention.
    later = System.system_time(:millisecond) + 31 * 60 * 1_000
    assert IdempotentStore.expire_due(later, 10) == 10
    assert IdempotentStore.expire_due(later, 10) == 10
    # Each status change replaced the job's index entry, so only 25 are due.
    assert IdempotentStore.expire_due(later, 10) == 5
    assert IdempotentStore.expire_due(later, 10) == 0

    for job <- jobs, do: assert(IdempotentStore.get_job(job.id) == nil)
    assert IdempotentStore.get_job(queued.id)
    assert IdempotentStore.counts() == %{total_jobs: 1, queue_depth: 1}

    # Their keys are free again.
    [first | _] = jobs
    again = %{first | id: "expire-again-#{System.unique_integer([:positive])}"}
    assert IdempotentStore.check_or_insert(again) == :ok
  end

  test "cleanup resumes from where the last batch stopped" do
    jobs = for i <- 1..25, do: insert("resume-#{i}")
    Enum.each(jobs, &complete/1)
    later = System.system_time(:millisecond) + 31 * 60 * 1_000

    {10, c1} = IdempotentStore.expire_due_from(later, 10, <<>>)
    {10, c2} = IdempotentStore.expire_due_from(later, 10, c1)
    {5, _} = IdempotentStore.expire_due_from(later, 10, c2)

    for job <- jobs, do: assert(IdempotentStore.get_job(job.id) == nil)
    assert IdempotentStore.counts() == %{total_jobs: 0, queue_depth: 0}
  end

  test "an index entry written before it carried the hash still expires" do
    job = insert("legacy")
    complete(job)
    later = System.system_time(:millisecond) + 31 * 60 * 1_000

    # Rewrite the job's entry the way older versions stored it.
    [{key, _}] = Spillway.Store.take_from(:expiry, <<>>, 1, fn _ -> true end)
    Spillway.Store.put(:expiry, key, nil)

    assert IdempotentStore.expire_due(later, 10) == 1
    assert IdempotentStore.get_job(job.id) == nil
    assert IdempotentStore.check_or_insert(%{job | id: "legacy-again"}) == :ok
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
