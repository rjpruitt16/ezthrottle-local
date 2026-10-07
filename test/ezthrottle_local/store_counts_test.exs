defmodule EzthrottleLocal.StoreCountsTest do
  @moduledoc """
  counts/0 feeds the load headers on every dispatch, so it reads running
  counters instead of scanning the jobs table. These tests check the
  counters against a full scan after every kind of write.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Job

  defp scan do
    rows = :mnesia.dirty_match_object({:jobs, :_, :_, :_, :_})
    pending = Enum.count(rows, fn {:jobs, _, _, _, status} -> status in [:queued, :in_flight] end)
    %{total_jobs: length(rows), queue_depth: pending}
  end

  defp job(stamp, i) do
    %Job{
      id: "counts-#{stamp}-#{i}",
      user_id: "counts-user",
      idempotent_key: "counts-key-#{stamp}-#{i}",
      url: "https://example.com/upstream",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  setup do
    IdempotentStore.clear_ledger()
    :ok
  end

  test "running counts match a full scan through insert, complete, fail, delete and clear" do
    stamp = System.unique_integer([:positive])
    jobs = for i <- 1..20, do: job(stamp, i)

    Enum.each(jobs, &(:ok = IdempotentStore.check_or_insert(&1)))
    assert IdempotentStore.counts() == %{total_jobs: 20, queue_depth: 20}

    # A duplicate inserts nothing.
    assert {:duplicate, _} = IdempotentStore.check_or_insert(%{hd(jobs) | id: "other"})
    assert IdempotentStore.counts() == scan()

    jobs |> Enum.take(5) |> Enum.each(&IdempotentStore.update_status(&1.id, :completed))
    jobs |> Enum.slice(5, 3) |> Enum.each(&IdempotentStore.update_status(&1.id, :failed))
    assert IdempotentStore.counts() == %{total_jobs: 20, queue_depth: 12}
    assert IdempotentStore.counts() == scan()

    # Deleting a finished job and a queued one.
    IdempotentStore.delete_job(Enum.at(jobs, 0))
    IdempotentStore.delete_job(Enum.at(jobs, 10))
    assert IdempotentStore.counts() == %{total_jobs: 18, queue_depth: 11}
    assert IdempotentStore.counts() == scan()

    IdempotentStore.clear_ledger()
    assert IdempotentStore.counts() == %{total_jobs: 0, queue_depth: 0}
  end

  test "rows left :in_flight by an older version count as queued and settle on completion" do
    stamp = System.unique_integer([:positive])
    legacy = job(stamp, 1)
    :ok = IdempotentStore.check_or_insert(legacy)

    :mnesia.dirty_write(
      {:jobs, legacy.id, legacy, System.system_time(:millisecond) + 60_000, :in_flight}
    )

    IdempotentStore.seed_counts()
    assert IdempotentStore.counts() == %{total_jobs: 1, queue_depth: 1}
    assert [%Job{id: id}] = IdempotentStore.recoverable_jobs()
    assert id == legacy.id

    IdempotentStore.update_status(legacy.id, :completed)
    assert IdempotentStore.counts() == %{total_jobs: 1, queue_depth: 0}
  end

  test "drain events are recorded only with drain mode on" do
    stamp = System.unique_integer([:positive])
    System.delete_env("EZTHROTTLE_DRAIN_ENABLED")
    off = job(stamp, 1)
    :ok = IdempotentStore.check_or_insert(off)
    IdempotentStore.update_status(off.id, :completed)
    assert IdempotentStore.list_drain_events() == []

    System.put_env("EZTHROTTLE_DRAIN_ENABLED", "true")
    on_exit(fn -> System.delete_env("EZTHROTTLE_DRAIN_ENABLED") end)
    on = job(stamp, 2)
    :ok = IdempotentStore.check_or_insert(on)
    IdempotentStore.update_status(on.id, :completed)
    assert [%{job_id: id}] = IdempotentStore.list_drain_events()
    assert id == on.id
  end
end
