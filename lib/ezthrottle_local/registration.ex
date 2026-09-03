defmodule EzthrottleLocal.Registration do
  @moduledoc """
  External registration: opt-in, off by default. When EZTHROTTLE_REGISTRY_URL
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

  Disabled by default means exactly that: application.ex only adds this
  process to the supervision tree when enabled?/0 is true at boot (see
  registration_children/0) -- not a process that starts and no-ops.
  """

  use GenServer

  require Logger

  alias EzthrottleLocal.Webhook

  @default_interval_seconds 15

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def url, do: System.get_env("EZTHROTTLE_REGISTRY_URL")

  def port, do: System.get_env("PORT", "4000")

  def interval_seconds,
    do: env_int("EZTHROTTLE_REGISTRY_INTERVAL_SECONDS", @default_interval_seconds)

  def enabled?, do: url() not in [nil, ""]

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
  def ping do
    payload = %{port: port(), reported_at: DateTime.utc_now() |> DateTime.to_iso8601()}

    case Webhook.deliver(url(), payload) do
      :ok ->
        :ok

      :error ->
        Logger.error("[Registration] failed to report state to #{url()} after retries")
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
