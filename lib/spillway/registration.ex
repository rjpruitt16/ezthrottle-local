# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.Registration do
  @moduledoc """
  External registration: opt-in, off by default. When SPILLWAY_REGISTRY_URL
  is set, this instance periodically reports its own listening port to that
  URL so an external control plane (Canalis, or anything else someone builds
  against the same contract) can assign tenants to it. Generic on purpose,
  not tied to any specific control plane. Delivered through Webhook.deliver/2
  -- the same retrying, L8-signed path drain mode's ledger flush already
  uses, rather than inventing new delivery machinery. Mirrors Aquifer's
  registration.go.

  Only the port is reported, not a full address -- whatever receives this
  ping already sees the real source IP on the connection itself, so a
  self-reported address would be redundant with that.

  `state` is the lifecycle state, same values as Aquifer's: `active` on
  normal heartbeats, `draining` as soon as shutdown starts (sent right
  away, see Spillway.Lifecycle), and a best-effort `offline` once accepted
  work is done. Optional fields, left out when unset: `reserved_for`
  (SPILLWAY_REGISTRY_RESERVED_FOR, this node is dedicated to one user_id),
  `role` (SPILLWAY_REGISTRY_ROLE, e.g. "http" or "ws"), and `drain_state`
  when drain mode is on -- kept apart from `state` because drain mode's
  "draining" means "finishing one tenant's burst", not "shutting down".

  Disabled by default means exactly that: application.ex only adds this
  process to the supervision tree when enabled?/0 is true at boot (see
  registration_children/0) -- not a process that starts and no-ops.
  """

  use GenServer

  require Logger

  alias Spillway.Webhook

  @default_interval_seconds 15

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def url, do: System.get_env("SPILLWAY_REGISTRY_URL")

  def port, do: System.get_env("PORT", "4000")

  def interval_seconds,
    do: env_int("SPILLWAY_REGISTRY_INTERVAL_SECONDS", @default_interval_seconds)

  def enabled?, do: url() not in [nil, ""]

  def reserved_for, do: env_trimmed("SPILLWAY_REGISTRY_RESERVED_FOR")

  def role do
    case env_trimmed("SPILLWAY_REGISTRY_ROLE") do
      nil -> nil
      role -> String.downcase(role)
    end
  end

  @doc """
  Reports a lifecycle change right away instead of on the next heartbeat.
  `"draining"` goes out in the background (shutdown shouldn't wait on it);
  `"offline"` is one synchronous best-effort attempt. No-op when disabled.
  """
  def report_lifecycle("draining") do
    if enabled?(), do: Task.start(fn -> ping() end)
    :ok
  end

  def report_lifecycle("offline") do
    if enabled?(), do: Webhook.deliver_once(url(), payload(state: "offline"))
    :ok
  end

  @doc """
  Called by AccountQueueRegistry the moment drain mode reaches
  `:unassigned` -- the control plane's cue to hand this node to another
  tenant -- so it doesn't sit idle until the next heartbeat. The state is
  passed in rather than read back, since the caller is the process that
  owns it.
  """
  def report_unassigned do
    if enabled?(), do: Task.start(fn -> ping(drain_state: :unassigned) end)
    :ok
  end

  @impl true
  def init(_init_arg) do
    # Ping immediately rather than waiting a full interval, so a
    # freshly-booted instance doesn't sit unregistered for the first tick.
    send(self(), :ping)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ping, state) do
    ping()
    Process.send_after(self(), :ping, interval_seconds() * 1_000)
    {:noreply, state}
  end

  @doc false
  def ping(overrides \\ []) do
    case Webhook.deliver(url(), payload(overrides)) do
      :ok ->
        :ok

      :error ->
        Logger.error("[Registration] failed to report state to #{url()} after retries")
    end
  end

  @doc false
  def payload(overrides \\ []) do
    state =
      Keyword.get_lazy(overrides, :state, fn ->
        if Spillway.Lifecycle.draining?(), do: "draining", else: "active"
      end)

    drain_state =
      Keyword.get_lazy(overrides, :drain_state, fn ->
        case safe_drain_snapshot() do
          %{state: drain_state} -> drain_state
          _ -> nil
        end
      end)

    %{port: port(), state: state, reported_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    |> put_if(:reserved_for, reserved_for())
    |> put_if(:role, role())
    |> put_if(:drain_state, drain_state && to_string(drain_state))
    |> Map.put(:fullness, safe_fullness())
  end

  # Same number as the x-aqueduct-fullness response header, so a control
  # plane knows how full this node is before sending it anything.
  defp safe_fullness do
    Spillway.Admission.fullness()
  rescue
    _ -> 0
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # The registry may not be running (tests, or very early in boot); a
  # missing drain_state is better than a crashed heartbeat.
  defp safe_drain_snapshot do
    Spillway.AccountQueueRegistry.drain_snapshot()
  catch
    :exit, _ -> nil
  end

  defp env_trimmed(key) do
    case System.get_env(key) do
      nil -> nil
      val -> if String.trim(val) == "", do: nil, else: String.trim(val)
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> default
        end
    end
  end
end
