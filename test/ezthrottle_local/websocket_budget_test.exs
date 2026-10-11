defmodule EzthrottleLocal.WebSocketBudgetTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [<<<: 2]

  alias EzthrottleLocal.{WebSocketBudget, WebSocketStore}

  setup do
    # Leave no limit behind for other tests.
    on_exit(fn -> WebSocketBudget.refresh(0, 0, 0, 1) end)
  end

  test "no limit under budget; an equal share of it when over" do
    assert WebSocketBudget.limit_for(100, 10, 2, 1_000) == nil
    # 2,000 bytes over 20 events is 100 bytes each; 1,000 bytes holds 10
    # events, shared by 2 sessions.
    assert WebSocketBudget.limit_for(2_000, 20, 2, 1_000) == 10
    # A floor of 10 events per session, however many sessions there are.
    assert WebSocketBudget.limit_for(2_000, 20, 1_000, 1_000) == 10
  end

  test "over budget, idle transcripts are trimmed to the limit, oldest first" do
    sessions = for n <- 1..3, do: "budget-#{System.unique_integer([:positive])}-#{n}"

    for session <- sessions, i <- 1..60 do
      {:ok, _} = WebSocketStore.append(session, "backend", %{"type" => "event", "n" => i})
    end

    first_cursors =
      Map.new(sessions, fn session ->
        {:ok, [first | _]} = WebSocketStore.read_after(session, "0-0", 1)
        {session, first.stream_id}
      end)

    # A budget of 1 byte: every session falls to the 10-event floor.
    # Freshly written streams count as active; treat them as idle here.
    WebSocketStore.enforce_budget(1, 0)
    assert WebSocketBudget.session_limit() == 10

    for session <- sessions do
      {:ok, events} = WebSocketStore.read_after(session, "0-0", 100)
      assert Enum.map(events, & &1.envelope["n"]) == Enum.to_list(51..60)

      # A client still holding a cursor from before the trim gets a gap,
      # which the controller turns into 409.
      assert WebSocketStore.check_cursor(session, first_cursors[session]) ==
               {:error, :replay_gap}
    end

    # Active transcripts are held to the limit on each append too.
    [session | _] = sessions
    {:ok, _} = WebSocketStore.append(session, "backend", %{"type" => "event", "n" => 61})
    {:ok, events} = WebSocketStore.read_after(session, "0-0", 100)
    assert Enum.map(events, & &1.envelope["n"]) == Enum.to_list(52..61)

    # Back under budget, the limit lifts.
    WebSocketStore.enforce_budget(1 <<< 40)
    assert WebSocketBudget.session_limit() == nil
  end

  test "the derived budget is what the rest of the node leaves, at most a quarter" do
    mb = 1_048_576
    # 2 GB machine, rest of the node at 100 MB: target 40% = 819 MB, so
    # 719 MB of room, capped at a quarter (512 MB).
    assert WebSocketBudget.derive_budget_bytes(2048, nil, 100 * mb) == 512 * mb
    # Rest of the node at 600 MB (the lab's overload): 219 MB of room.
    assert WebSocketBudget.derive_budget_bytes(2048, nil, 600 * mb) ==
             trunc(2048 * 0.4 * mb) - 600 * mb

    # Past the target, the floor.
    assert WebSocketBudget.derive_budget_bytes(2048, nil, 900 * mb) == 16 * mb
    # EZTHROTTLE_MEMORY_LIMIT_MB=400: target 90% = 360 MB, ceiling 100 MB.
    assert WebSocketBudget.derive_budget_bytes(2048, 400, 200 * mb) == 100 * mb
    assert WebSocketBudget.derive_budget_bytes(2048, 400, 300 * mb) == trunc(360 * mb) - 300 * mb
  end

  test "EZTHROTTLE_WS_TRANSCRIPT_MAX_MB overrides the derived budget" do
    System.put_env("EZTHROTTLE_WS_TRANSCRIPT_MAX_MB", "32")
    assert WebSocketBudget.budget_bytes(0) == 32 * 1_048_576
  after
    System.delete_env("EZTHROTTLE_WS_TRANSCRIPT_MAX_MB")
  end
end
