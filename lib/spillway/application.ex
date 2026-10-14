# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  # Runs on SIGTERM (init:stop) before the supervision tree shuts down, while
  # the endpoint still serves /ready and can reject new work.
  @impl true
  def prep_stop(state) do
    Spillway.Lifecycle.drain()
    state
  end

  @impl true
  def start(_type, _args) do
    configure_httpc_ipfamily()
    Spillway.IdempotentStore.ensure_schema!()
    Spillway.WebSocketStore.ensure_tables!()
    Spillway.UserLoad.ensure_table!()
    websocket_config = Spillway.WebSocketConfig.load()

    SpillwayWeb.Plugs.InFlightLimit.setup()

    # Read before the endpoint takes traffic, so the scan sees only jobs
    # from the previous run; Spillway.Recovery puts them back on their
    # queues once the node is up.
    recovered = Spillway.IdempotentStore.recoverable_jobs()

    children =
      [
        # Opened in ensure_schema! above; this process syncs its log and
        # owns the idempotency key gate.
        Spillway.Store,
        SpillwayWeb.Telemetry,
        {Cluster.Supervisor, [Spillway.Cluster.topologies(), [name: Spillway.ClusterSupervisor]]},
        {Phoenix.PubSub, name: Spillway.PubSub},
        # Pooled, persistent connections for upstream and webhook dispatch
        # (AccountQueue.make_request/6). inet6: true tries IPv6 first and
        # falls back to IPv4, matching the :httpc ipfamily below, so Fly's
        # IPv6-only private network still works. Each pool is one process
        # that hands out connections; with one per scheduler a 1-CPU node
        # had a single process for every request, and under load its
        # checkout queue backed up. At least 8 spreads that out.
        {Finch,
         name: Spillway.Finch,
         pools: %{
           default: [
             size: 64,
             count: max(System.schedulers_online(), 8),
             conn_opts: [transport_opts: [inet6: true]]
           ]
         }}
      ] ++
        Spillway.WebSocketStore.Valkey.child_specs() ++
        [
          {Registry, keys: :unique, name: Spillway.WebSocketStreamOwners},
          {Spillway.WebSocketStore, websocket_config},
          {Spillway.WebSocketQueue, websocket_config},
          {Registry, keys: :unique, name: Spillway.WebSocketSessionRegistry},
          Spillway.WebSocketSessionSupervisor,
          Spillway.L8
        ] ++
        l8_schema_children() ++
        [
          Spillway.Admission,
          Spillway.IdempotentStore,
          Spillway.PoolRegistry,
          Spillway.RemoteBacklog,
          Spillway.AccountQueueRegistry,
          {Spillway.Recovery, recovered}
        ] ++
        region_redirect_children() ++ registration_children() ++ [SpillwayWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Spillway.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Cross-region /proxy redirect (Spillway.Redirect) -- the region
  # poller, the redirect gate, and the IPv6 listener below all stay
  # entirely out of the supervision tree unless SPILLWAY_FLY_REGIONS is
  # actually set, mirroring Aquifer's NewFlyRegionAdapter returning nil so
  # the feature is off unless explicitly configured. Also flips the
  # RegionAdapter dispatcher (Spillway.RegionAdapter) over to the
  # real implementation, the same way :metrics_adapter is wired.
  defp region_redirect_children do
    case Spillway.RegionAdapter.Fly.configured_regions() do
      [] ->
        []

      _regions ->
        Application.put_env(:spillway, :region_adapter, Spillway.RegionAdapter.Fly)

        [
          Spillway.RegionAdapter.Fly,
          Spillway.Redirect.gate_child_spec(),
          ipv6_listener_child_spec()
        ]
    end
  end

  # Same opt-in-means-no-process convention: the L8 request-schema cache only
  # exists when SPILLWAY_L8_SCHEMA_VALIDATION=true.
  defp l8_schema_children do
    if Spillway.L8.Schemas.enabled?(), do: [Spillway.L8.Schemas], else: []
  end

  # Spillway.Registration stays entirely out of the supervision
  # tree unless SPILLWAY_REGISTRY_URL is actually set -- same
  # opt-in-means-no-process-at-all convention region_redirect_children/0
  # already follows.
  defp registration_children do
    if Spillway.Registration.enabled?() do
      [Spillway.Registration]
    else
      []
    end
  end

  # The main SpillwayWeb.Endpoint listener binds IPv4-only
  # (config/runtime.exs's ip: {0, 0, 0, 0}) -- deliberately, because Fly's
  # own health-check/process scanning for the *public* [http_service] port
  # explicitly looks for a raw IPv4 listener and flags the app unreachable
  # otherwise (see that config's own comment). But Fly's private 6PN
  # network -- what sibling-region health checks and redirect hops both
  # arrive over -- is IPv6-only, so an IPv4-only bind means those
  # connections get reset even though the app is otherwise perfectly
  # healthy (confirmed this exact failure mode in aqueduct-runner's
  # recorder while testing Aquifer's version of this feature: Flask's
  # host="0.0.0.0" had the identical problem). Rather than touch the
  # existing, deliberately-IPv4 public listener at all, run a second,
  # independent Bandit listener bound IPv6-any on the same port, serving
  # the exact same Endpoint plug -- private 6PN traffic (both /health and
  # /proxy hops) gets a working path in, the public listener and its
  # already-solved Fly-scanning behavior are completely untouched.
  #
  # ipv6_v6only: true is the critical piece -- confirmed by an actual local
  # boot (not assumed): without it, this listener claims the IPv4 space too
  # under this OS's dual-stack default, and the *existing* IPv4-only
  # listener then fails to bind at all (:eaddrinuse), crashing the whole
  # app. With it, the two listeners are genuinely independent sockets.
  defp ipv6_listener_child_spec do
    port = String.to_integer(System.get_env("PORT", "4000"))

    Supervisor.child_spec(
      {Bandit,
       plug: SpillwayWeb.Endpoint,
       scheme: :http,
       ip: {0, 0, 0, 0, 0, 0, 0, 0},
       port: port,
       thousand_island_options: [transport_options: [ipv6_v6only: true]]},
      id: SpillwayWeb.Endpoint.IPv6Listener
    )
  end

  # Erlang's :httpc defaults to IPv4-only resolution (ipfamily: :inet) --
  # confirmed live against real Fly infrastructure while testing this
  # feature: a region-prefixed .internal hostname (AAAA-only, no A record,
  # since Fly's 6PN is IPv6-only) got :nxdomain from :httpc even though the
  # OS-level resolver (getent) found it fine, and even a literal IPv6
  # address string still failed the same way, because :httpc's own connect
  # logic defaults to :inet family regardless of what the address looks
  # like. :inet6fb4 (try IPv6, fall back to IPv4) fixes reachability for
  # RegionAdapter.Fly's health checks and Redirect's hop calls without
  # narrowing anything IPv4/dual-stack (account_queue.ex's make_request)
  # already reaches -- applies globally to the default httpc profile since
  # both code paths share it.
  defp configure_httpc_ipfamily do
    :httpc.set_options(ipfamily: :inet6fb4)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SpillwayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
