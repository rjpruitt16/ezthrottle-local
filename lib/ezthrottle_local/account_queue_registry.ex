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
  alias EzthrottleLocal.Jitter
  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.Cluster
  alias EzthrottleLocal.Intake
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
    job
    |> actor_for()
    |> route_to_actor(:enqueue, job, account_queue_header)
  end

  @doc """
  Claims the job's cluster-wide queue, then persists and admits it on that
  owner node.

  On a standalone node the owner is always this node, so the persist step
  (the Mnesia insert and instance admission) runs here in the caller's
  process instead of inside the UrlActor and AccountQueue processes. Those
  are one per domain, and doing the insert inside them made every
  submission and webhook for a domain wait in line for the one before it.
  """
  def submit(%Job{} = job, account_queue_header \\ nil) do
    pid = actor_for(job)

    if Cluster.standalone?() do
      case AccountQueue.prepare_submission(job, true) do
        {:prepared, prepared} -> admit_here(pid, prepared, account_queue_header, :new)
        other -> other
      end
    else
      route_to_actor(pid, :submit, job, account_queue_header)
    end
  end

  def submit_internal(%Job{} = job, account_queue_header \\ nil) do
    pid = actor_for(job)

    if Cluster.standalone?() do
      case AccountQueue.prepare_submission(job, false) do
        {:prepared, prepared} -> admit_here(pid, prepared, account_queue_header, :internal)
        other -> other
      end
    else
      route_to_actor(pid, :submit_internal, job, account_queue_header)
    end
  end

  def prepare(%Job{} = job, account_queue_header \\ nil) do
    pid = actor_for(job)

    if Cluster.standalone?() do
      apply_account_queue_header(pid, account_queue_header)
      AccountQueue.prepare_submission(job, true)
    else
      route_to_actor(pid, :prepare, job, account_queue_header)
    end
  end

  def enqueue_prepared(%Job{} = job, account_queue_header \\ nil) do
    pid = actor_for(job)

    if Cluster.standalone?() do
      case admit_here(pid, job, account_queue_header, :new) do
        {:accepted, _job} -> :ok
        other -> other
      end
    else
      route_to_actor(pid, :enqueue_prepared, job, account_queue_header)
    end
  end

  # Standalone fast path: reserve, decide and hand off in this process (see
  # EzthrottleLocal.Intake) instead of going through the domain's UrlActor.
  defp admit_here(actor, job, account_queue_header, mode) do
    domain = route_key(job)
    sync_account_queue_header(actor, domain, account_queue_header)

    case Intake.admit(actor, domain, job, mode, &replace_actor(job, &1)) do
      :ok ->
        {:accepted, job}

      {:rejected, _reason, _limit, _current} = rejected ->
        IdempotentStore.delete_job(job)
        rejected
    end
  end

  # The header switches a domain's mode. Only a request asking for a mode
  # the domain isn't already in calls the actor, synchronously, so that
  # request itself is routed under the new mode.
  defp sync_account_queue_header(_actor, _domain, nil), do: :ok

  defp sync_account_queue_header(actor, domain, header) do
    wanted =
      case header |> to_string() |> String.trim() |> String.downcase() do
        "enabled" -> true
        "disabled" -> false
        _ -> nil
      end

    current =
      case :ets.lookup(:ez_queues, {:settings, domain}) do
        [{_, enabled, _}] -> enabled
        [] -> nil
      end

    if wanted != nil and wanted != current do
      GenServer.call(actor, {:account_queue_header, if(wanted, do: "enabled", else: "disabled")})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Queues a webhook delivery through the same domain-keyed account-queue
  pacing and backpressure machinery as forward dispatch (RPS/concurrency
  limits, X-Aqueduct-*/X-EZThrottle-* response-header throttling) instead
  of firing immediately with a fixed retry schedule -- a slow or
  rate-limited webhook receiver can now shed load exactly the way an
  upstream API already can, and delivery is durable across a restart the
  same way a real job is (the underlying webhook-delivery Job is
  persisted by the cluster-wide queue owner, not just held in an in-memory
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

    case submit_internal(job) do
      {:accepted, _job} -> :ok
      {:duplicate, _existing_job_id} -> :ok
      {:rejected, _reason, _limit, _current} -> :ok
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
  def actor_for(%Job{pool_id: nil, url: url} = job) when is_binary(url) do
    # Read the actor table directly; only spawning a new actor needs the
    # registry process, which every submission used to call.
    key = url_key(url)

    case :ets.lookup(@default_table, key) do
      # The registry monitors actors and removes them on exit, so no
      # liveness check (which would wait behind a busy actor's mailbox).
      [{^key, pid}] ->
        pid

      [] ->
        GenServer.call(__MODULE__, {:actor_for, job})
    end
  rescue
    ArgumentError -> GenServer.call(__MODULE__, {:actor_for, job})
  end

  def actor_for(%Job{} = job) do
    GenServer.call(__MODULE__, {:actor_for, job})
  end

  @doc """
  A live actor for job when `stale` turned out to have exited (it retires
  once it has no queues, and a direct table read can return it before this
  registry has processed its exit). Drops the entry only if it still points
  at `stale`.
  """
  def replace_actor(%Job{} = job, stale) do
    GenServer.call(__MODULE__, {:replace_actor, job, stale})
  end

  @doc "See UrlActor.breaker_open?/1 -- resolves the actor for this job first."
  def breaker_open?(%Job{} = job) do
    UrlActor.breaker_open?(actor_for(job))
  end

  @doc "See UrlActor.breaker_kind/1 -- resolves the actor for this job first."
  def breaker_kind(%Job{} = job) do
    UrlActor.breaker_kind(actor_for(job))
  end

  @doc "See UrlActor.queue_active?/1 -- resolves the actor for this job first."
  def queue_active?(%Job{} = job) do
    UrlActor.queue_active?(actor_for(job))
  end

  def queue_snapshot(%Job{} = job) do
    pid = actor_for(job)

    if Cluster.standalone?(),
      do: Intake.snapshot(pid, route_key(job), job),
      else: UrlActor.queue_snapshot(pid, job)
  end

  def node_queue_snapshot do
    snapshots =
      Cluster.all_account_queues()
      |> Enum.uniq()
      |> Enum.filter(&(node(&1) == node()))
      |> Enum.map(fn pid ->
        try do
          AccountQueue.snapshot(pid)
        catch
          :exit, _reason -> %{backlog: 0, active: false}
        end
      end)

    %{
      active: Enum.count(snapshots, & &1.active),
      backlog: Enum.sum(Enum.map(snapshots, & &1.backlog))
    }
  end

  @doc "See UrlActor.trip_breaker/3 -- resolves the actor for this job first."
  def trip_breaker(%Job{} = job, cooldown_ms, kind) do
    UrlActor.trip_breaker(actor_for(job), cooldown_ms, kind)
  end

  def update_max_backlog(%Job{} = job, max_backlog) do
    GenServer.call(actor_for(job), {:max_backlog_header, max_backlog})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{table: table}) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    EzthrottleLocal.Intake.ensure_tables()

    # Drain mode's watchdog: only scheduled at all if enabled?/0 is true at
    # startup -- disabled means exactly that no periodic check ever runs,
    # not a check that runs and no-ops. See EzthrottleLocal.DrainFlush.
    if DrainFlush.enabled?() do
      schedule_idle_check()
      if DrainFlush.batch_enabled?(), do: schedule_batch_flush()
    end

    {:ok, %{table: table, became_idle_at: nil, drain_state: :active}}
  end

  @impl true
  def handle_call(:drain_state, _from, state) do
    {:reply, state.drain_state, state}
  end

  @impl true
  def handle_call({:enqueue, job, account_queue_header}, _from, state) do
    route_job(:enqueue, job, account_queue_header, state)
  end

  @impl true
  def handle_call({:submit, job, account_queue_header}, _from, state) do
    route_job(:submit, job, account_queue_header, state)
  end

  @impl true
  def handle_call({:submit_internal, job, account_queue_header}, _from, state) do
    route_job(:submit_internal, job, account_queue_header, state)
  end

  @impl true
  def handle_call({:prepare, job, account_queue_header}, _from, state) do
    route_job(:prepare, job, account_queue_header, state)
  end

  @impl true
  def handle_call({:enqueue_prepared, job, account_queue_header}, _from, state) do
    route_job(:enqueue_prepared, job, account_queue_header, state)
  end

  @impl true
  def handle_call({:actor_for, job}, _from, state) do
    {:reply, resolve_actor(state, job), state}
  end

  def handle_call({:replace_actor, job, stale}, _from, state) do
    {route_key, _pool} = route_key_and_pool(job)
    :ets.delete_object(state.table, {route_key, stale})
    {:reply, resolve_actor(state, job), state}
  end

  defp route_job(action, job, account_queue_header, state) do
    pid = resolve_actor(state, job)
    result = route_to_actor(pid, action, job, account_queue_header)

    {:reply, result, state}
  end

  defp route_to_actor(pid, action, job, account_queue_header) do
    apply_account_queue_header(pid, account_queue_header)

    case action do
      :submit -> UrlActor.submit(pid, job)
      :submit_internal -> UrlActor.submit_internal(pid, job)
      :prepare -> UrlActor.prepare(pid, job)
      :enqueue_prepared -> UrlActor.enqueue_prepared(pid, job)
      :enqueue -> UrlActor.enqueue(pid, job)
    end
  end

  defp apply_account_queue_header(pid, account_queue_header) do
    if account_queue_header do
      mode = account_queue_header |> to_string() |> String.trim() |> String.downcase()

      case mode do
        "enabled" -> UrlActor.enable_account_queue(pid)
        "disabled" -> UrlActor.disable_account_queue(pid)
        _ -> :ok
      end
    end
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

  @impl true
  def handle_info(:drain_batch_flush, state) do
    DrainFlush.flush_batch()
    schedule_batch_flush()
    {:noreply, state}
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

  defp schedule_batch_flush do
    Process.send_after(
      self(),
      :drain_batch_flush,
      (DrainFlush.batch_interval_seconds() * 1_000) |> Jitter.add_ms()
    )
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

        Process.unlink(new_pid)
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
  defp route_key(%Job{pool_id: pool_id}) when is_binary(pool_id), do: "pool:" <> pool_id
  defp route_key(%Job{url: url}), do: url_key(url)

  defp route_key_and_pool(%Job{pool_id: pool_id}) when is_binary(pool_id) do
    {"pool:" <> pool_id, PoolRegistry.get_or_create(pool_id)}
  end

  defp route_key_and_pool(%Job{url: url}) do
    {url_key(url), nil}
  end
end
