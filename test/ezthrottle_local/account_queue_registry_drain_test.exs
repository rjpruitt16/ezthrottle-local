defmodule EzthrottleLocal.AccountQueueRegistryDrainTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueueRegistry

  # AccountQueueRegistry is a globally-named singleton GenServer started
  # once for the whole test run (its :url_actors ETS table is also a
  # single shared, named table other tests register real UrlActors into),
  # so unlike Aquifer's Registry -- constructed fresh per test with its own
  # isolated state -- there's no way to spin up an isolated instance here
  # to deterministically drive it through :active -> :draining ->
  # :unassigned via the real periodic :idle_check message: whether
  # :ets.info(:url_actors, :size) == 0 at any given moment depends on
  # whatever other tests' UrlActors happen to still be registered. The
  # actual flush-then-clear-only-on-success sequencing this state machine
  # wraps is already covered end-to-end in drain_flush_test.exs, which
  # calls DrainFlush.attempt/0 directly rather than through this registry.
  # What's left, and reliably testable against the live singleton: the
  # gating logic itself.
  test "drain_snapshot/0 is nil when drain mode is disabled (the test env default)" do
    assert AccountQueueRegistry.drain_snapshot() == nil
  end
end
