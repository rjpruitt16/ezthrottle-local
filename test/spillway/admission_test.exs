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
