# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.RegistrationTest do
  @moduledoc """
  Mirrors Aquifer's registration_test.go.
  """

  use ExUnit.Case, async: false

  alias Spillway.Registration

  setup do
    on_exit(fn ->
      System.delete_env("SPILLWAY_REGISTRY_URL")
      System.delete_env("PORT")
      System.delete_env("SPILLWAY_REGISTRY_INTERVAL_SECONDS")
    end)
  end

  test "disabled by default with no SPILLWAY_REGISTRY_URL set" do
    System.delete_env("SPILLWAY_REGISTRY_URL")
    refute Registration.enabled?()
  end

  test "port defaults to 4000, matching the same PORT convention application.ex already uses" do
    System.delete_env("PORT")
    assert Registration.port() == "4000"
  end

  defmodule RegistrationPingPlug do
    import Plug.Conn

    def init(opts), do: opts

    # L8.ensure_trust/1 (called by Webhook.deliver/2 before the real POST)
    # does its own preliminary GET /.well-known/l8 handshake probe first --
    # not the payload this test cares about. Same guard Aquifer's own
    # tests use (skipL8Probe in registry_test.go) for the identical
    # request Aquifer's L8Registry makes.
    def call(%{request_path: "/.well-known/l8"} = conn, _opts) do
      send_resp(conn, 404, "")
    end

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      send(Keyword.fetch!(opts, :test_pid), {:ping_received, decoded["port"]})
      send_resp(conn, 200, "")
    end
  end

  test "pings immediately and again on the next interval, reporting the real listening port" do
    test_pid = self()

    port = Enum.random(20_000..60_000)
    child_id = :"registration_test_#{port}"

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: {RegistrationPingPlug, test_pid: test_pid}, port: port},
        id: child_id
      )
    )

    System.put_env("SPILLWAY_REGISTRY_URL", "http://127.0.0.1:#{port}")
    System.put_env("PORT", "9999")
    System.put_env("SPILLWAY_REGISTRY_INTERVAL_SECONDS", "1")

    assert Registration.enabled?()

    start_supervised!(Registration)

    assert_receive {:ping_received, "9999"}, 2_000
    assert_receive {:ping_received, "9999"}, 3_000
  end
end

defmodule Spillway.RegistrationPayloadTest do
  @moduledoc """
  The fields a control plane like Canalis reads from the ping, beyond the
  port: lifecycle state, reserved_for, role, and drain mode's own state.
  """

  use ExUnit.Case, async: false

  alias Spillway.Registration

  setup do
    on_exit(fn ->
      for key <-
            ~w(SPILLWAY_REGISTRY_URL SPILLWAY_REGISTRY_RESERVED_FOR SPILLWAY_REGISTRY_ROLE SPILLWAY_REGISTRY_POOLS) do
        System.delete_env(key)
      end

      Spillway.Lifecycle.reset()
    end)
  end

  test "reports active, and leaves optional fields out when they're unset" do
    payload = Registration.payload()

    assert payload.state == "active"
    refute Map.has_key?(payload, :reserved_for)
    refute Map.has_key?(payload, :role)
    refute Map.has_key?(payload, :pools)
  end

  test "reports the pools it joins, dropping blanks" do
    System.put_env("SPILLWAY_REGISTRY_POOLS", " gpu, ,eu ")
    assert Registration.payload().pools == ["gpu", "eu"]
  end

  test "reports draining once shutdown has started" do
    Spillway.Lifecycle.begin_drain()
    assert Registration.payload().state == "draining"
  end

  test "reports reserved_for and role, trimmed and lowercased" do
    System.put_env("SPILLWAY_REGISTRY_RESERVED_FOR", " acme ")
    System.put_env("SPILLWAY_REGISTRY_ROLE", "WS")

    payload = Registration.payload()
    assert payload.reserved_for == "acme"
    assert payload.role == "ws"
  end

  test "an explicit drain_state wins over reading it back" do
    assert Registration.payload(drain_state: :unassigned).drain_state == "unassigned"
  end

  defmodule BodyPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(Keyword.fetch!(opts, :test_pid), {:ping, Jason.decode!(body)})
      send_resp(conn, 200, "")
    end
  end

  test "offline and unassigned are reported right away, not on the next heartbeat" do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {BodyPlug, test_pid: self()}, port: port},
        id: :"registration_body_#{port}"
      )
    )

    System.put_env("SPILLWAY_REGISTRY_URL", "http://127.0.0.1:#{port}")

    Registration.report_lifecycle("offline")
    assert_receive {:ping, %{"state" => "offline"}}, 2_000

    Registration.report_unassigned()
    assert_receive {:ping, %{"drain_state" => "unassigned", "state" => "active"}}, 2_000
  end
end
