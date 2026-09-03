defmodule EzthrottleLocal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    configure_httpc_ipfamily()
    configure_mnesia_dir()
    EzthrottleLocal.IdempotentStore.ensure_schema!()

    children =
      [
        EzthrottleLocalWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:ezthrottle_local, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: EzthrottleLocal.PubSub},
        EzthrottleLocal.L8,
        EzthrottleLocal.Admission,
        EzthrottleLocal.IdempotentStore,
        EzthrottleLocal.PoolRegistry,
        EzthrottleLocal.AccountQueueRegistry
      ] ++ region_redirect_children() ++ registration_children() ++ [EzthrottleLocalWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EzthrottleLocal.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        recover_queued_jobs()
        ok

      other ->
        other
    end
  end

  # Cross-region /proxy redirect (EzthrottleLocal.Redirect) -- the region
  # poller, the redirect gate, and the IPv6 listener below all stay
  # entirely out of the supervision tree unless EZTHROTTLE_FLY_REGIONS is
  # actually set, mirroring Aquifer's NewFlyRegionAdapter returning nil so
  # the feature is off unless explicitly configured. Also flips the
  # RegionAdapter dispatcher (EzthrottleLocal.RegionAdapter) over to the
  # real implementation, the same way :metrics_adapter is wired.
  defp region_redirect_children do
    case EzthrottleLocal.RegionAdapter.Fly.configured_regions() do
      [] ->
        []

      _regions ->
        Application.put_env(:ezthrottle_local, :region_adapter, EzthrottleLocal.RegionAdapter.Fly)

        [
          EzthrottleLocal.RegionAdapter.Fly,
          EzthrottleLocal.Redirect.gate_child_spec(),
          ipv6_listener_child_spec()
        ]
    end
  end

  # EzthrottleLocal.Registration stays entirely out of the supervision
  # tree unless EZTHROTTLE_REGISTRY_URL is actually set -- same
  # opt-in-means-no-process-at-all convention region_redirect_children/0
  # already follows.
  defp registration_children do
    if EzthrottleLocal.Registration.enabled?() do
      [EzthrottleLocal.Registration]
    else
      []
    end
  end

  # The main EzthrottleLocalWeb.Endpoint listener binds IPv4-only
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
       plug: EzthrottleLocalWeb.Endpoint,
       scheme: :http,
       ip: {0, 0, 0, 0, 0, 0, 0, 0},
       port: port,
       thousand_island_options: [transport_options: [ipv6_v6only: true]]},
      id: EzthrottleLocalWeb.Endpoint.IPv6Listener
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

  # Mnesia's :dir is read at :mnesia.start()/:mnesia.create_schema() time,
  # so it has to be set before EzthrottleLocal.IdempotentStore.ensure_schema!
  # runs. MNESIA_DIR should point at a persistent volume in production
  # (mirrors Aquifer's DB_PATH) — without that, disc_copies data lives on
  # the machine's ephemeral filesystem and durability is lost on redeploy.
  defp configure_mnesia_dir do
    dir = Application.get_env(:ezthrottle_local, :mnesia_dir, "priv/mnesia")
    File.mkdir_p!(dir)
    Application.put_env(:mnesia, :dir, to_charlist(dir))
  end

  # Jobs left at :queued or :in_flight when the node last stopped have no
  # way to resume on their own — this is what makes the Mnesia switch an
  # actual durability guarantee rather than just "writes happen to
  # survive on disk but nothing ever picks them back up."
  defp recover_queued_jobs do
    jobs = EzthrottleLocal.IdempotentStore.recoverable_jobs()

    if jobs != [] do
      Logger.info("recovering #{length(jobs)} queued/in-flight jobs from Mnesia")
      Enum.each(jobs, &EzthrottleLocal.AccountQueueRegistry.enqueue/1)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EzthrottleLocalWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
