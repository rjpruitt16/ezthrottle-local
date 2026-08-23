defmodule EzthrottleLocal.PoolTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.Pool

  setup do
    {:ok, pid} = Pool.start_link("test-#{System.unique_integer([:positive])}")
    %{pool: pid}
  end

  test "pick is proportional to weight, not equal-split round robin", %{pool: pool} do
    :ok = Pool.register(pool, "fast", "http://fast", 100.0, 60_000)
    :ok = Pool.register(pool, "slow", "http://slow", 25.0, 60_000)

    counts =
      Enum.reduce(1..2000, %{}, fn _, acc ->
        member = Pool.pick(pool)
        assert member != nil
        Map.update(acc, member.id, 1, &(&1 + 1))
      end)

    ratio = counts["fast"] / counts["slow"]

    assert ratio > 3.0 and ratio < 5.5,
           "expected roughly 4x more picks for the 100rps member, got #{inspect(counts)} (ratio #{ratio})"
  end

  test "a new member seeds at the current minimum, not 0", %{pool: pool} do
    :ok = Pool.register(pool, "veteran", "http://veteran", 50.0, 60_000)
    for _ <- 1..100, do: Pool.pick(pool)

    :ok = Pool.register(pool, "newcomer", "http://newcomer", 50.0, 60_000)

    counts =
      Enum.reduce(1..200, %{}, fn _, acc ->
        member = Pool.pick(pool)
        Map.update(acc, member.id, 1, &(&1 + 1))
      end)

    newcomer = Map.get(counts, "newcomer", 0)

    assert newcomer > 60 and newcomer < 140,
           "expected a roughly even split after fair seeding, got #{inspect(counts)}"
  end

  test "pick on an empty pool returns nil", %{pool: pool} do
    assert Pool.pick(pool) == nil
  end

  test "reputation halves on failure and partially recovers on success", %{pool: pool} do
    :ok = Pool.register(pool, "flaky", "http://flaky", 10.0, 60_000)

    [%{reputation: rep0}] = Pool.snapshot(pool)
    assert rep0 == 1.0

    Pool.record_failure(pool, "flaky")
    [%{reputation: rep1}] = Pool.snapshot(pool)
    assert_in_delta rep1, 0.5, 0.0001

    Pool.record_failure(pool, "flaky")
    [%{reputation: rep2}] = Pool.snapshot(pool)
    assert_in_delta rep2, 0.25, 0.0001

    Pool.record_success(pool, "flaky")
    [%{reputation: rep3}] = Pool.snapshot(pool)
    assert rep3 > rep2 and rep3 < 1.0
  end

  test "heartbeat gradually recovers reputation without resetting to full trust", %{pool: pool} do
    :ok = Pool.register(pool, "restarted", "http://old", 10.0, 60_000)
    Pool.record_failure(pool, "restarted")
    Pool.record_failure(pool, "restarted")

    [%{reputation: before}] = Pool.snapshot(pool)
    :ok = Pool.register(pool, "restarted", "http://new", 10.0, 60_000)
    [%{reputation: after_heartbeat}] = Pool.snapshot(pool)

    assert after_heartbeat > before
    assert after_heartbeat < 1.0
  end

  test "does not evict immediately on reaching the floor", %{pool: pool} do
    :ok = Pool.register(pool, "dying", "http://dying", 10.0, 60_000)

    evicted = Enum.map(1..5, fn _ -> Pool.record_failure(pool, "dying") end)

    refute Enum.any?(evicted), "should not evict immediately on reaching the floor"
    assert Pool.size(pool) == 1
  end

  test "evicts once the sustained floor window elapses with no interrupting success" do
    prev = Application.get_env(:ezthrottle_local, :pool_floor_eviction_window_ms)
    Application.put_env(:ezthrottle_local, :pool_floor_eviction_window_ms, 30)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezthrottle_local, :pool_floor_eviction_window_ms)
        val -> Application.put_env(:ezthrottle_local, :pool_floor_eviction_window_ms, val)
      end
    end)

    {:ok, pool} = Pool.start_link("floor-eviction-#{System.unique_integer([:positive])}")
    :ok = Pool.register(pool, "dying", "http://dying", 10.0, 60_000)
    for _ <- 1..5, do: Pool.record_failure(pool, "dying")
    assert Pool.size(pool) == 1

    Process.sleep(50)

    assert Pool.record_failure(pool, "dying") == true
    assert Pool.size(pool) == 0
  end

  test "success clears the floor timer even if reputation is still below the floor", %{
    pool: pool
  } do
    :ok = Pool.register(pool, "dying", "http://dying", 10.0, 60_000)
    for _ <- 1..5, do: Pool.record_failure(pool, "dying")

    Pool.record_success(pool, "dying")

    # A fresh run of failures from here should not evict immediately --
    # if the floor timer had carried over instead of resetting, this
    # would need far fewer failures to cross the sustained window.
    evicted = Enum.map(1..3, fn _ -> Pool.record_failure(pool, "dying") end)
    refute Enum.any?(evicted)
    assert Pool.size(pool) == 1
  end

  test "heartbeat sweep evicts members that go silent, independent of reputation", %{
    pool: pool
  } do
    :ok = Pool.register(pool, "responsive", "http://responsive", 10.0, 100)
    :ok = Pool.register(pool, "silent", "http://silent", 10.0, 100)

    Process.sleep(100)
    :ok = Pool.register(pool, "responsive", "http://responsive", 10.0, 100)
    Process.sleep(250)

    send(pool, :heartbeat_sweep)
    Process.sleep(20)

    assert Pool.size(pool) == 1
    ids = Pool.snapshot(pool) |> Enum.map(& &1.id)
    assert ids == ["responsive"]
  end

  test "total_capacity is a live sum that reflects reputation decay", %{pool: pool} do
    :ok = Pool.register(pool, "a", "http://a", 30.0, 60_000)
    :ok = Pool.register(pool, "b", "http://b", 20.0, 60_000)

    assert_in_delta Pool.total_capacity(pool), 50.0, 0.0001

    Pool.record_failure(pool, "a")
    assert_in_delta Pool.total_capacity(pool), 35.0, 0.0001
  end

  test "PoolRegistry routes by pool_id and lazily creates on Get" do
    alias EzthrottleLocal.PoolRegistry

    :ok =
      PoolRegistry.register(
        "writers-#{System.unique_integer([:positive])}",
        "w1",
        "http://w1",
        40.0,
        60_000
      )

    empty_pool_id = "nobody-registered-#{System.unique_integer([:positive])}"
    pid = PoolRegistry.get_or_create(empty_pool_id)
    assert is_pid(pid)
    assert Pool.size(pid) == 0
  end
end
