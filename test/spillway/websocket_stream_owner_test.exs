# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.WebSocketStreamOwnerTest do
  use ExUnit.Case, async: false

  alias Spillway.{WebSocketBudget, WebSocketStore}

  setup do
    on_exit(fn -> WebSocketBudget.refresh(0, 0, 0, 1) end)
  end

  # Claims the stream in its own process, like a session, and forwards what
  # it receives to the test.
  defp owner(session) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:claimed, WebSocketStore.claim_stream(session)})

        receive_loop = fn loop ->
          receive do
            {:trim_transcript, limit} = msg ->
              send(test, msg)
              WebSocketStore.trim_owned(session, limit)
              send(test, :trimmed)
              loop.(loop)

            :stop ->
              :ok
          end
        end

        receive_loop.(receive_loop)
      end)

    assert_receive {:claimed, :ok}
    pid
  end

  test "one owner per stream; the next one waits until it exits" do
    session = "owner-#{System.unique_integer([:positive])}"
    first = owner(session)

    assert {:error, {:stream_owned_by, ^first}} = WebSocketStore.claim_stream(session, 2)

    send(first, :stop)
    second = owner(session)
    assert is_pid(second)
    send(second, :stop)
  end

  test "the budget pass leaves a live session's stream to the session" do
    session = "owned-trim-#{System.unique_integer([:positive])}"
    pid = owner(session)

    for i <- 1..60 do
      {:ok, _} = WebSocketStore.append(session, "backend", %{"type" => "event", "n" => i})
    end

    WebSocketStore.enforce_budget(1, 0)
    assert_receive {:trim_transcript, 10}
    assert_receive :trimmed

    {:ok, events} = WebSocketStore.read_after(session, "0-0", 100)
    assert Enum.map(events, & &1.envelope["n"]) == Enum.to_list(51..60)
    send(pid, :stop)
  end
end
