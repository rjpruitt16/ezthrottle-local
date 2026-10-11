defmodule Spillway.AccountQueueRegistryDrainTest do
  use ExUnit.Case, async: false

  alias Spillway.{AccountQueueRegistry, IdempotentStore}

  # Accepts the drain flush. The ledger is shared with async tests, which
  # can add entries after clear_ledger/0; with an unreachable webhook URL
  # the flush then retried for seconds and the registry's :drain_state
  # call timed out.
  defmodule AcceptFlush do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "")
  end

  # AccountQueueRegistry is a globally-named singleton in production (one
  # shared instance for the whole app, its :url_actors ETS table shared
  # across every caller). That's not testable in isolation directly -- but
  # start_link/1 now accepts :name and :table overrides (defaulting to the
  # production values, so nothing about the real supervision tree changes)
  # specifically so tests can spin up their own private instance, the same
  # way Aquifer's NewRegistry already allowed per-test. An isolated
  # instance is driven via raw GenServer.call/send to its own pid, not
  # through this module's public functions (which stay hardcoded to the
  # production name).
  #
  # These env vars are process-global, not per-test -- explicit on_exit
  # cleanup below, matching the pattern already used in drain_flush_test.exs.

  test "drain_snapshot/0 is nil when drain mode is disabled (the test env default)" do
    assert AccountQueueRegistry.drain_snapshot() == nil
  end

  test "an isolated instance with drain mode disabled never schedules the watchdog, state stays active" do
    System.delete_env("SPILLWAY_DRAIN_ENABLED")
    System.delete_env("SPILLWAY_DRAIN_WEBHOOK_URL")

    {:ok, pid} =
      AccountQueueRegistry.start_link(
        name: :"registry_disabled_#{System.unique_integer([:positive])}",
        table: :"url_actors_disabled_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # Long enough to cross a real watchdog tick (5s) -- if :idle_check had
    # been scheduled despite being disabled, this would catch it.
    Process.sleep(7_000)

    assert GenServer.call(pid, :drain_state) == :active
  end

  @tag timeout: 30_000
  test "an isolated instance with drain mode enabled transitions active -> draining -> unassigned" do
    IdempotentStore.clear_ledger()

    System.put_env("SPILLWAY_DRAIN_ENABLED", "true")
    System.put_env("SPILLWAY_DRAIN_TIMER_SECONDS", "1")
    port = Enum.random(20_000..60_000)
    start_supervised!({Bandit, plug: AcceptFlush, port: port})
    System.put_env("SPILLWAY_DRAIN_WEBHOOK_URL", "http://127.0.0.1:#{port}/drain")

    on_exit(fn ->
      System.delete_env("SPILLWAY_DRAIN_ENABLED")
      System.delete_env("SPILLWAY_DRAIN_TIMER_SECONDS")
      System.delete_env("SPILLWAY_DRAIN_WEBHOOK_URL")
    end)

    {:ok, pid} =
      AccountQueueRegistry.start_link(
        name: :"registry_enabled_#{System.unique_integer([:positive])}",
        table: :"url_actors_enabled_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # First tick: the isolated table starts empty (nothing was ever routed
    # through this instance), so it's idle from the start -- moves
    # active -> draining.
    Process.sleep(7_000)
    assert GenServer.call(pid, :drain_state) == :draining

    # Second tick: TimerSeconds(1) has long since elapsed -- attempts a
    # flush, which either takes the empty-ledger fast path or is accepted
    # by AcceptFlush -> unassigned.
    Process.sleep(7_000)
    assert GenServer.call(pid, :drain_state) == :unassigned
  end
end
