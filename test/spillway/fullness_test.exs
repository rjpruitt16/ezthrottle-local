# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.FullnessTest do
  @moduledoc """
  x-aqueduct-fullness: how full this node is, 0-100, from the limits it
  already enforces. Mirrors Aquifer's fullness_test.go.
  """

  use ExUnit.Case, async: false
  import Plug.Test

  alias Spillway.{Admission, Intake}

  @limits ~w(SPILLWAY_MEMORY_LIMIT_MB SPILLWAY_DB_MAX_BYTES SPILLWAY_STORE_MAX_BACKLOG
              SPILLWAY_MAX_EXPIRY_LAG_SECONDS)

  setup do
    prev = Map.new(@limits, &{&1, System.get_env(&1)})

    for key <- @limits, do: System.put_env(key, "0")

    on_exit(fn ->
      for {key, value} <- prev do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "is 0 with every limit switched off and nothing queued" do
    assert Admission.compute_fullness() == 0
  end

  test "follows memory against its limit" do
    current = Spillway.MemoryUsage.mb()
    System.put_env("SPILLWAY_MEMORY_LIMIT_MB", Integer.to_string(current * 2))

    assert Admission.compute_fullness() in 40..60
  end

  test "follows the fullest upstream's backlog against its budget" do
    Intake.ensure_tables()
    domain = "fullness-#{System.unique_integer([:positive])}.test"
    queue = spawn(fn -> Process.sleep(:infinity) end)

    Intake.publish_settings(domain, false, 10)
    Intake.register_queue(domain, :shared, queue)
    :ets.insert(:ez_queue_backlog, {queue, 7})

    on_exit(fn ->
      :ets.delete(:ez_queue_backlog, queue)
      :ets.delete(:ez_queues, {:settings, domain})
      Intake.unregister_queue(domain, :shared, queue)
      Process.exit(queue, :kill)
    end)

    assert Intake.backlog_fullness_ratio() >= 0.7
    assert Admission.compute_fullness() >= 70
  end

  test "goes on every response" do
    conn = conn(:get, "/health") |> SpillwayWeb.Endpoint.call([])

    assert [value] = Plug.Conn.get_resp_header(conn, "x-aqueduct-fullness")
    assert String.to_integer(value) in 0..100
  end

  test "is in the registration ping" do
    assert Spillway.Registration.payload().fullness in 0..100
  end
end
