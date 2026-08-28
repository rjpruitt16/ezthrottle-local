defmodule EzthrottleLocal.AccountQueueRegistry do
  @moduledoc """
  Top-level registry for UrlActors.
  Routes incoming jobs to the correct UrlActor based on destination URL domain.
  Spawns UrlActors on demand and monitors them for cleanup.
  """

  use GenServer

  alias EzthrottleLocal.UrlActor
  alias EzthrottleLocal.Job
  alias EzthrottleLocal.PoolRegistry
  alias EzthrottleLocal.DrainFlush
  alias EzthrottleLocal.IdempotentStore

  @default_table :url_actors
  @idle_check_interval_ms 5_000

  # ---- Public API ----

  @doc """
  Starts the registry. In production this is always called with no opts
  (via the supervision tree), giving the single global instance named
  `__MODULE__` with ETS table `:url_actors` -- the defaults below exist
  only so tests can start additional, isolated instances (different
  `:name`, different `:table`) to deterministically drive the idle
  watchdog without racing the real singleton's shared, suite-wide state.
  An isolated test instance is interacted with via raw `GenServer.call`/
  `send` to its own pid, not through this module's public functions below
  (which are hardcoded to the production name).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = Keyword.get(opts, :table, @default_table)
    GenServer.start_link(__MODULE__, %{table: table}, name: name)
  end

  @doc """
  Route a job to the correct UrlActor, spawning one if needed.
  account_queue_header is the raw X-Aqueduct-Account-Queue/
  X-EZThrottle-Account-Queue value from the originating request, or nil if
  this job has no live request behind it (e.g. recovered from Mnesia at
  startup). nil leaves the UrlActor's current account-queue mode
  unchanged rather than forcing it off — the mode is shared per upstream
  domain, so one request that doesn't care about it shouldn't be able to
  flip it off for every other concurrent tenant relying on it being on.
  """
  def enqueue(%Job{} = job, account_queue_header \\ nil) do
    GenServer.call(__MODULE__, {:enqueue, job, account_queue_header})
  end

  @doc """
  Queues a webhook delivery through the same domain-keyed account-queue
  pacing and backpressure machinery as forward dispatch (RPS/concurrency
  limits, X-Aqueduct-*/X-EZThrottle-* response-header throttling) instead
  of firing immediately with a fixed retry schedule -- a slow or
  rate-limited webhook receiver can now shed load exactly the way an
  upstream API already can, and delivery is durable across a restart the
  same way a real job is (the underlying webhook-delivery Job is
  persisted via IdempotentStore.check_or_insert/1, not just an in-memory
  retry loop).

  original_job_id scopes the idempotent key (see Job.new_webhook_delivery/4)
  so a given job's webhook is enqueued at most once even if this were
  somehow called twice for it.
  """
  def enqueue_webhook(_original_job_id, _user_id, webhook_url, _payload)
      when webhook_url in [nil, ""],
      do: :ok

  def enqueue_webhook(original_job_id, user_id, webhook_url, payload) do
    job = Job.new_webhook_delivery(original_job_id, user_id, webhook_url, payload)

    case IdempotentStore.check_or_insert(job) do
      :ok -> enqueue(job)
      {:duplicate, _existing_job_id} -> :ok
    end
  end

  @doc """
  Drain mode's current state (:active | :draining | :unassigned) for
  GET /health, or nil when drain mode isn't enabled -- an instance that
  never turned this on shouldn't see a new key appear in its health
  output. See EzthrottleLocal.DrainFlush.
  """
  def drain_snapshot do
    if DrainFlush.enabled?() do
      %{state: GenServer.call(__MODULE__, :drain_state)}
    end
  end

  @doc """
  Resolves (spawning if necessary) the UrlActor pid that would handle this
  job's dispatch, without enqueueing anything onto it. Used by proxy
  mode's circuit breaker (EzthrottleLocal.Proxy) to check/trip breaker
  state before a job is ever actually queued.
  """
  def actor_for(%Job{} = job) do
    GenServer.call(__MODULE__, {:actor_for, job})
  end

  @doc "See UrlActor.breaker_open?/1 -- resolves the actor for this job first."
  def breaker_open?(%Job{} = job) do
    UrlActor.breaker_open?(actor_for(job))
  end

  @doc "See UrlActor.queue_active?/1 -- resolves the actor for this job first."
  def queue_active?(%Job{} = job) do
    UrlActor.queue_active?(actor_for(job))
  end

  @doc "See UrlActor.trip_breaker/2 -- resolves the actor for this job first."
  def trip_breaker(%Job{} = job, cooldown_ms) do
    UrlActor.trip_breaker(actor_for(job), cooldown_ms)
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{table: table}) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    # Drain mode's watchdog: only scheduled at all if enabled?/0 is true at
    # startup -- disabled means exactly that no periodic check ever runs,
    # not a check that runs and no-ops. See EzthrottleLocal.DrainFlush.
    if DrainFlush.enabled?() do
      schedule_idle_check()
    end

    {:ok, %{table: table, became_idle_at: nil, drain_state: :active}}
  end

  @impl true
  def handle_call(:drain_state, _from, state) do
    {:reply, state.drain_state, state}
  end

  @impl true
  def handle_call({:enqueue, job, account_queue_header}, _from, state) do
    pid = resolve_actor(state, job)

    if account_queue_header do
      mode = account_queue_header |> to_string() |> String.trim() |> String.downcase()

      case mode do
        "enabled" -> UrlActor.enable_account_queue(pid)
        "disabled" -> UrlActor.disable_account_queue(pid)
        _ -> :ok
      end
    end

    UrlActor.enqueue(pid, job)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:actor_for, job}, _from, state) do
    {:reply, resolve_actor(state, job), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(state.table, {:_, pid})
    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    idle? = :ets.info(state.table, :size) == 0
    new_state = check_idle(idle?, state)
    schedule_idle_check()
    {:noreply, new_state}
  end

  # ---- Private ----

  # Mirrors Aquifer's drainWatchdogLoop, made explicit as a small state
  # machine (:active | :draining | :unassigned) rather than two implicit
  # booleans, both for readability and so it's queryable via drain_snapshot/0
  # for GET /health: not idle resets to :active; newly idle moves to
  # :draining; already :unassigned this idle period skips a re-flush;
  # otherwise, once idle long enough, attempts a flush -- a failure leaves
  # the state at :draining so the next tick retries from scratch, safely,
  # since a failed attempt never clears anything.
  defp check_idle(false, state), do: %{state | became_idle_at: nil, drain_state: :active}

  defp check_idle(true, %{became_idle_at: nil} = state) do
    %{state | became_idle_at: System.monotonic_time(:millisecond), drain_state: :draining}
  end

  defp check_idle(true, %{drain_state: :unassigned} = state), do: state

  defp check_idle(true, %{became_idle_at: became_idle_at} = state) do
    elapsed_ms = System.monotonic_time(:millisecond) - became_idle_at

    if elapsed_ms >= DrainFlush.timer_seconds() * 1_000 do
      if DrainFlush.attempt() do
        %{state | drain_state: :unassigned}
      else
        state
      end
    else
      state
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_check_interval_ms)
  end

  # Resolves (spawning if necessary) the UrlActor pid for a job's routing
  # key -- the exact lookup-or-spawn logic {:enqueue, ...} always did
  # inline, now shared with {:actor_for, ...} so proxy mode's breaker check
  # can resolve the same actor without enqueueing anything onto it.
  defp resolve_actor(state, job) do
    {route_key, pool_pid} = route_key_and_pool(job)

    case :ets.lookup(state.table, route_key) do
      [{^route_key, existing_pid}] ->
        existing_pid

      [] ->
        {:ok, new_pid} =
          UrlActor.start_link(url_key: route_key, domain: route_key, pool_pid: pool_pid)

        Process.monitor(new_pid)
        :ets.insert(state.table, {route_key, new_pid})
        new_pid
    end
  end

  # Matches Aquifer's domainKey (url_worker.go) exactly, including the
  # port -- a real porting gap found while adding webhook-delivery jobs to
  # this same routing: two backends that differ only by port (e.g.
  # http://host:8080 and http://host:9090, a common same-host-different-
  # service topology) were previously collapsing into one shared
  # rate-limit queue instead of being paced independently, since only
  # scheme+host was ever compared here.
  defp url_key(url) do
    uri = URI.parse(url)
    port_suffix = if uri.port, do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  end

  # Pool-backed jobs route by pool_id instead of the destination domain,
  # since there is no single fixed domain -- PoolRegistry.get_or_create
  # lazily creates the pool if nobody's registered to it yet, so a
  # pool-backed job always gets pool-mode dispatch behavior (failing
  # cleanly with "no pool members registered" if empty) instead of
  # silently falling through to a non-pool dispatch path with no URL.
  defp route_key_and_pool(%Job{pool_id: pool_id}) when is_binary(pool_id) do
    {"pool:" <> pool_id, PoolRegistry.get_or_create(pool_id)}
  end

  defp route_key_and_pool(%Job{url: url}) do
    {url_key(url), nil}
  end
end
