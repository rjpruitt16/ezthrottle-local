# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.AdmissionTest do
  use ExUnit.Case, async: false

  alias Spillway.Admission

  setup do
    # Admission reads its limits fresh from the environment on every call,
    # and tracks reject-streak state in a shared Agent — reset both around
    # each test so tests don't leak state into each other.
    prev = %{
      mem: System.get_env("SPILLWAY_MEMORY_LIMIT_MB"),
      body: System.get_env("SPILLWAY_MAX_BODY_BYTES"),
      db: System.get_env("SPILLWAY_DB_MAX_BYTES"),
      retry: System.get_env("SPILLWAY_RETRY_AFTER_SECONDS"),
      backlog: System.get_env("SPILLWAY_STORE_MAX_BACKLOG")
    }

    on_exit(fn ->
      restore_env("SPILLWAY_MEMORY_LIMIT_MB", prev.mem)
      restore_env("SPILLWAY_MAX_BODY_BYTES", prev.body)
      restore_env("SPILLWAY_DB_MAX_BYTES", prev.db)
      restore_env("SPILLWAY_RETRY_AFTER_SECONDS", prev.retry)
      restore_env("SPILLWAY_STORE_MAX_BACKLOG", prev.backlog)
      reset_streak()
    end)

    reset_streak()
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp reset_streak do
    # Drive the streak back to 0 the same way production does: one
    # allowed check. Requires no limits configured at the moment this runs.
    System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")
    System.delete_env("SPILLWAY_DB_MAX_BYTES")
    Admission.check()
  end

  test "memory stays disabled by default, body/db default on, with no env vars set" do
    System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")
    System.delete_env("SPILLWAY_MAX_BODY_BYTES")
    System.delete_env("SPILLWAY_DB_MAX_BYTES")

    assert Admission.memory_limit_mb() == 0
    assert Admission.max_body_bytes() == 1 * 1024 * 1024
    assert Admission.db_max_bytes() == 800 * 1024 * 1024
    assert Admission.any_limit_configured?()
    # The Mnesia dir in a test run is well under the 800MB default, so a
    # real check() still passes even with a size ceiling on by default.
    assert :ok = Admission.check()
  end

  test "explicit 0 still disables body/db limits" do
    System.put_env("SPILLWAY_MAX_BODY_BYTES", "0")
    System.put_env("SPILLWAY_DB_MAX_BYTES", "0")

    assert Admission.max_body_bytes() == 0
    assert Admission.db_max_bytes() == 0
  end

  test "rejects over memory limit" do
    # 1MB is far below what a running BEAM node actually uses, so this
    # deterministically trips the check without allocating anything.
    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", "1")

    assert {:rejected, "memory", 1, current} = Admission.check()
    assert current > 1
  end

  test "retry_after_seconds doubles on consecutive rejections and resets on allow" do
    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", "1")
    System.put_env("SPILLWAY_RETRY_AFTER_SECONDS", "5")

    {:rejected, _, _, _} = Admission.check()
    assert Admission.retry_after_seconds() == 5

    {:rejected, _, _, _} = Admission.check()
    assert Admission.retry_after_seconds() == 10

    {:rejected, _, _, _} = Admission.check()
    assert Admission.retry_after_seconds() == 20

    System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")
    :ok = Admission.check()
    assert Admission.retry_after_seconds() == 5
  end

  test "retry_after_seconds costs the same however long the rejection streak" do
    System.put_env("SPILLWAY_RETRY_AFTER_SECONDS", "5")
    :atomics.put(:persistent_term.get({Admission, :counters}), 1, 10_000_000)
    {micros, value} = :timer.tc(&Admission.retry_after_seconds/0)
    assert value == 60
    assert micros < 1_000
  end

  test "retry_after_seconds caps at 60" do
    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", "1")
    System.put_env("SPILLWAY_RETRY_AFTER_SECONDS", "5")

    for _ <- 1..10, do: Admission.check()

    assert Admission.retry_after_seconds() == 60
  end

  test "rejects while the store backlog is over its limit" do
    System.put_env("SPILLWAY_STORE_MAX_BACKLOG", "1")
    # A stand-in for a per-table RocksDB process that isn't keeping up.
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    Process.register(pid, :mnesia_ext_proc_admission_test)

    try do
      for _ <- 1..5, do: send(pid, :write)
      Process.sleep(300)
      assert {:rejected, "store_backlog", 1, n} = Admission.check()
      assert n >= 5
    after
      send(pid, :stop)
    end
  end

  describe "background readings" do
    setup do
      on_exit(fn ->
        Application.delete_env(:spillway, :admission_db_bytes_reader)
        Admission.refresh()
      end)
    end

    test "rejects on the database size the background reading found" do
      System.put_env("SPILLWAY_DB_MAX_BYTES", "1000")
      Application.put_env(:spillway, :admission_db_bytes_reader, fn -> 5_000 end)
      Admission.refresh()

      assert {:rejected, "db_size", 1000, 5_000} = Admission.check()
      assert Admission.snapshot().db_bytes == 5_000
    end

    # Soak run 3e: requests read the directory size themselves, each walk
    # took minutes under load, and nearly every in-flight slot was spent
    # waiting on one.
    test "submissions never wait on a slow directory walk" do
      System.put_env("SPILLWAY_DB_MAX_BYTES", "1000000000")
      parent = self()

      Application.put_env(:spillway, :admission_db_bytes_reader, fn ->
        send(parent, :walking)
        Process.sleep(2_000)
        1
      end)

      send(Admission, :refresh)
      assert_receive :walking, 2_000

      {micros, results} =
        :timer.tc(fn ->
          1..200
          |> Task.async_stream(fn _ -> Admission.check() end, max_concurrency: 200)
          |> Enum.map(fn {:ok, r} -> r end)
        end)

      assert Enum.all?(results, &(&1 == :ok))
      assert micros < 500_000
    end
  end

  test "snapshot reports enabled true by default (body/db defaults), false only if explicitly all disabled" do
    System.delete_env("SPILLWAY_MEMORY_LIMIT_MB")
    System.delete_env("SPILLWAY_MAX_BODY_BYTES")
    System.delete_env("SPILLWAY_DB_MAX_BYTES")
    assert Admission.snapshot().enabled

    System.put_env("SPILLWAY_MAX_BODY_BYTES", "0")
    System.put_env("SPILLWAY_DB_MAX_BYTES", "0")
    System.put_env("SPILLWAY_STORE_MAX_BACKLOG", "0")
    refute Admission.snapshot().enabled

    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", "1000000")
    assert Admission.snapshot().enabled
  end
end
