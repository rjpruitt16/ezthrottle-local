defmodule EzthrottleLocal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
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
      ] ++ region_redirect_children() ++ [EzthrottleLocalWeb.Endpoint]

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

  # Cross-region /proxy redirect (EzthrottleLocal.Redirect) -- both the
  # region poller and the redirect gate stay entirely out of the
  # supervision tree unless EZTHROTTLE_FLY_REGIONS is actually set,
  # mirroring Aquifer's NewFlyRegionAdapter returning nil so the feature is
  # off unless explicitly configured. Also flips the RegionAdapter
  # dispatcher (EzthrottleLocal.RegionAdapter) over to the real
  # implementation, the same way :metrics_adapter is wired.
  defp region_redirect_children do
    case EzthrottleLocal.RegionAdapter.Fly.configured_regions() do
      [] ->
        []

      _regions ->
        Application.put_env(:ezthrottle_local, :region_adapter, EzthrottleLocal.RegionAdapter.Fly)
        [EzthrottleLocal.RegionAdapter.Fly, EzthrottleLocal.Redirect.gate_child_spec()]
    end
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
