defmodule EzthrottleLocal.UrlActor do
  @moduledoc """
  GenServer per destination URL domain.

  By default all traffic flows through a single shared queue for this URL.
  When X-EZTHROTTLE-ACCOUNT-QUEUE: enabled is received in a response header,
  the UrlActor switches to per-user AccountQueue isolation — one queue per
  user_id + api_key. This can also be enabled via config.

  AccountQueue mode is off by default. Enable it when you need per-user
  fairness and noisy neighbor isolation.
  """

  use GenServer

  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.Cluster
  alias EzthrottleLocal.Job
  alias EzthrottleLocal.Pool
  alias EzthrottleLocal.FairAdmission
  alias EzthrottleLocal.IdempotentStore

  @default_idle_timeout_seconds 300
  @shared_queue_key :shared
  @min_rps 0.5

  # How often to check whether the sum of every active tenant queue's
  # current rate exceeds this worker's actual budget (static config, or
  # live pool capacity), throttling proportionally if so. Without this,
  # account-queue mode isolates tenants from each other but doesn't bound
  # them collectively -- N simultaneously active tenants could each
  # independently believe they own the full ceiling, multiplying real
  # load on the upstream by N. Ported from the same fix in Aquifer
  # (url_worker.go's enforceAggregateBudget).
  @budget_check_ms 3_000

  defstruct [
    :url_key,
    :domain,
    :pool_pid,
    rps: 2.0,
    max_concurrent: 1,
    account_queue_enabled: false,
    queues: %{},
    breaker_until_ms: nil,
    breaker_kind: nil,
    slow_start_enabled: false,
    max_backlog: 10_000
  ]

  # ---- Public API ----

  def start_link(opts) do
    url_key = Keyword.fetch!(opts, :url_key)
    domain = Keyword.fetch!(opts, :domain)
    pool_pid = Keyword.get(opts, :pool_pid)
    GenServer.start_link(__MODULE__, %{url_key: url_key, domain: domain, pool_pid: pool_pid})
  end

  def enqueue(pid, %Job{} = job) do
    GenServer.call(pid, {:enqueue, job})
  end

  def submit(pid, %Job{} = job) do
    GenServer.call(pid, {:submit, job}, 15_000)
  end

  def submit_internal(pid, %Job{} = job) do
    GenServer.call(pid, {:submit_internal, job}, 15_000)
  end

  def prepare(pid, %Job{} = job) do
    GenServer.call(pid, {:prepare, job}, 15_000)
  end

  def enqueue_prepared(pid, %Job{} = job) do
    GenServer.call(pid, {:enqueue_prepared, job}, 15_000)
  end

  @doc "Fair admission and enqueue for a job the caller already persisted (a new submission)."
  def admit_new(pid, %Job{} = job) do
    GenServer.call(pid, {:admit_new, job}, 15_000)
  end

  @doc "Writes this domain's admission settings to ETS for EzthrottleLocal.Intake."
  def publish_settings(pid), do: GenServer.call(pid, :publish_settings)

  @doc "The queue for queue_key, spawning it if needed (Intake's slow path)."
  def ensure_queue(pid, queue_key), do: GenServer.call(pid, {:ensure_queue, queue_key}, 15_000)

  def update_rps(pid, rps) do
    GenServer.cast(pid, {:update_rps, rps})
  end

  def update_max_concurrent(pid, max) do
    GenServer.cast(pid, {:update_max_concurrent, max})
  end

  def enable_account_queue(pid) do
    GenServer.cast(pid, :enable_account_queue)
  end

  def disable_account_queue(pid) do
    GenServer.cast(pid, :disable_account_queue)
  end

  @doc """
  Reports whether proxy mode should skip a direct dispatch attempt to this
  domain entirely and fall straight back to the durable queue -- set by
  trip_breaker/2 after an overload signal, cleared automatically once the
  cooldown elapses. Mirrors Aquifer's URLWorker.BreakerOpen.
  """
  def breaker_open?(pid) do
    GenServer.call(pid, :breaker_open?)
  end

  @doc """
  Which kind of signal tripped the breaker last -- "queue" or "reroute"
  (see EzthrottleLocal.Proxy.classify_overload/2) -- only meaningful while
  breaker_open?/1 is true. A subsequent request arriving while the breaker
  is still open has no fresh response of its own to classify, so it
  reuses whichever kind actually tripped it: a domain breaker-tripped by a
  429 stays queue-only on every retry during that cooldown, not
  reroute-eligible just because SOME overload happened. Mirrors Aquifer's
  URLWorker.BreakerKind.
  """
  def breaker_kind(pid) do
    GenServer.call(pid, :breaker_kind)
  end

  @doc """
  Opens the breaker for cooldown_ms, recording which kind of signal
  caused it (see breaker_kind/1). No separate half-open state is needed:
  once the cooldown elapses, breaker_open?/1 naturally returns false
  again, so the next request is itself a real probe against the live
  upstream -- success leaves the breaker closed, a repeat overload signal
  re-trips it via another trip_breaker/3 call. Mirrors Aquifer's
  URLWorker.TripBreaker.
  """
  def trip_breaker(pid, cooldown_ms, kind) do
    GenServer.cast(pid, {:trip_breaker, cooldown_ms, kind})
  end

  @doc """
  Whether any of this domain's account queues currently has real backlog
  (queued or in-flight work). Distinct from breaker_open?/1: a breaker
  cooldown is a fixed clock that can expire while a real backlog is still
  draining, letting proxy mode resume direct dispatch against an upstream
  that's still catching up from the very overload that tripped the breaker.
  queue_active?/1 self-corrects instead -- it stays true for exactly as
  long as there's real work in flight, independent of any timer, and goes
  false the instant the backlog is actually empty. Mirrors Aquifer's
  URLWorker.QueueActive.
  """
  def queue_active?(pid) do
    GenServer.call(pid, :queue_active?)
  end

  def queue_snapshot(pid, %Job{} = job), do: GenServer.call(pid, {:queue_snapshot, job})

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{url_key: url_key, domain: domain, pool_pid: pool_pid}) do
    default_rps = Application.get_env(:ezthrottle_local, :default_rps, 2.0)
    account_queue_enabled = Application.get_env(:ezthrottle_local, :account_queue_enabled, false)

    initial_state = %__MODULE__{
      url_key: url_key,
      domain: domain,
      pool_pid: pool_pid,
      rps: default_rps,
      account_queue_enabled: account_queue_enabled,
      max_backlog: FairAdmission.max_pending_per_upstream()
    }

    Phoenix.PubSub.subscribe(EzthrottleLocal.PubSub, cluster_topic(domain))
    state = initial_state |> hydrate_cluster_state() |> publish()
    :ok = Cluster.join_url_actor(domain, self())

    # No schedule_budget_check/0 here -- see handle_call({:enqueue, ...})
    # below, which is what actually starts it, and
    # handle_info(:check_aggregate_budget, ...) for the matching "stop
    # rescheduling once idle" half of the fix. Starting this unconditionally
    # at init, forever, was a real bug: it permanently blocked this
    # process's own 5-minute idle-timeout from ever elapsing, the same way
    # AccountQueue's schedule_position_broadcast/0 did one level down --
    # confirmed via aqueduct-runner as why drain mode could never flush.
    {:ok, state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    route_to_queue(:enqueue, job, state)
  end

  @impl true
  def handle_call({:submit, job}, _from, state) do
    route_to_queue(:submit, job, state)
  end

  @impl true
  def handle_call({:submit_internal, job}, _from, state) do
    route_to_queue(:submit_internal, job, state)
  end

  @impl true
  def handle_call(:cluster_snapshot, _from, state) do
    {:reply,
     Map.take(state, [
       :rps,
       :max_concurrent,
       :account_queue_enabled,
       :breaker_until_ms,
       :breaker_kind,
       :slow_start_enabled,
       :max_backlog
     ]), state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:prepare, job}, _from, state) do
    route_to_queue(:prepare, job, state)
  end

  @impl true
  def handle_call(:publish_settings, _from, state) do
    {:reply, :ok, publish(state), idle_timeout_ms()}
  end

  @impl true
  def handle_call({:ensure_queue, queue_key}, _from, state) do
    was_empty = map_size(state.queues) == 0
    {queue_pid, new_state} = find_or_spawn_queue(queue_key, state)
    if was_empty, do: schedule_budget_check()
    {:reply, queue_pid, new_state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:admit_new, job}, _from, state) do
    route_to_queue(:admit_new, job, state)
  end

  @impl true
  def handle_call({:enqueue_prepared, job}, _from, state) do
    route_to_queue(:enqueue_prepared, job, state)
  end

  @impl true
  def handle_call({:account_queue_header, "enabled"}, _from, state) do
    broadcast_cluster_state(state, :account_queue_enabled, true)
    {:reply, :ok, publish(%{state | account_queue_enabled: true}), idle_timeout_ms()}
  end

  @impl true
  def handle_call({:account_queue_header, "disabled"}, _from, state) do
    broadcast_cluster_state(state, :account_queue_enabled, false)
    {:reply, :ok, publish(%{state | account_queue_enabled: false}), idle_timeout_ms()}
  end

  @doc """
  Set by an upstream's X-Aqueduct-Slow-Start response header. Applies to
  the *next* new queue spawned for this domain (find_or_spawn_queue/2
  reads it), not the queue whose response carried the header -- that one's
  already running past the point where a starting rate matters -- and not
  retroactively. Mirrors Aquifer's URLWorker.slowStart.
  """
  @impl true
  def handle_call({:slow_start_header, enabled}, _from, state) do
    broadcast_cluster_state(state, :slow_start_enabled, enabled)
    {:reply, :ok, %{state | slow_start_enabled: enabled}, idle_timeout_ms()}
  end

  @impl true
  def handle_call(:breaker_open?, _from, state) do
    open? =
      case state.breaker_until_ms do
        nil -> false
        until_ms -> System.system_time(:millisecond) < until_ms
      end

    {:reply, open?, state, idle_timeout_ms()}
  end

  @impl true
  def handle_call(:breaker_kind, _from, state) do
    {:reply, state.breaker_kind, state, idle_timeout_ms()}
  end

  @impl true
  def handle_call(:queue_active?, _from, state) do
    active? = state |> all_queue_pids() |> Enum.any?(&AccountQueue.active?/1)
    {:reply, active?, state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:queue_snapshot, job}, _from, state) do
    {:reply, queue_snapshot_for_job(state, job), state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:max_backlog_header, max_backlog}, _from, state) do
    broadcast_cluster_state(state, :max_backlog, max_backlog)
    {:reply, :ok, publish(%{state | max_backlog: max_backlog}), idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    Enum.each(all_queue_pids(state), &AccountQueue.update_rps(&1, rps))
    broadcast_cluster_state(state, :rps, rps)

    {:noreply, %{state | rps: rps}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:update_max_concurrent, max}, state) do
    Enum.each(all_queue_pids(state), &AccountQueue.update_max_concurrent(&1, max))
    broadcast_cluster_state(state, :max_concurrent, max)

    {:noreply, %{state | max_concurrent: max}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast(:enable_account_queue, state) do
    broadcast_cluster_state(state, :account_queue_enabled, true)
    {:noreply, publish(%{state | account_queue_enabled: true}), idle_timeout_ms()}
  end

  @impl true
  def handle_cast(:disable_account_queue, state) do
    broadcast_cluster_state(state, :account_queue_enabled, false)
    {:noreply, publish(%{state | account_queue_enabled: false}), idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:trip_breaker, cooldown_ms, kind}, state) do
    # This expiry is included in cluster snapshots and PubSub messages, so
    # it must be comparable on another BEAM VM. Monotonic timestamps are
    # only meaningful within the VM that produced them.
    until_ms = System.system_time(:millisecond) + cooldown_ms
    broadcast_cluster_state(state, :breaker, {until_ms, kind})
    {:noreply, %{state | breaker_until_ms: until_ms, breaker_kind: kind}, idle_timeout_ms()}
  end

  @impl true
  def handle_info({:account_queue_header, "enabled"}, state) do
    {:noreply, publish(%{state | account_queue_enabled: true}), idle_timeout_ms()}
  end

  @impl true
  def handle_info({:account_queue_header, "disabled"}, state) do
    {:noreply, publish(%{state | account_queue_enabled: false}), idle_timeout_ms()}
  end

  @impl true
  def handle_info({:cluster_url_state, :rps, rps}, state) do
    Enum.each(all_queue_pids(state), &AccountQueue.update_rps(&1, rps))
    {:noreply, %{state | rps: rps}, idle_timeout_ms()}
  end

  def handle_info({:cluster_url_state, :max_concurrent, max}, state) do
    Enum.each(all_queue_pids(state), &AccountQueue.update_max_concurrent(&1, max))
    {:noreply, %{state | max_concurrent: max}, idle_timeout_ms()}
  end

  def handle_info({:cluster_url_state, :account_queue_enabled, enabled}, state) do
    {:noreply, publish(%{state | account_queue_enabled: enabled}), idle_timeout_ms()}
  end

  def handle_info({:cluster_url_state, :slow_start_enabled, enabled}, state) do
    {:noreply, %{state | slow_start_enabled: enabled}, idle_timeout_ms()}
  end

  def handle_info({:cluster_url_state, :max_backlog, max_backlog}, state) do
    {:noreply, publish(%{state | max_backlog: max_backlog}), idle_timeout_ms()}
  end

  def handle_info({:cluster_url_state, :breaker, {until_ms, kind}}, state) do
    {:noreply, %{state | breaker_until_ms: until_ms, breaker_kind: kind}, idle_timeout_ms()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {gone, kept} = Enum.split_with(state.queues, fn {_key, p} -> p == pid end)

    Enum.each(gone, fn {key, p} ->
      EzthrottleLocal.Intake.unregister_queue(state.domain, key, p)
    end)

    queues = Map.new(kept)
    new_state = %{state | queues: queues}

    # A child AccountQueue dying is exactly the signal that this actor
    # might now be empty -- check right here and self-terminate
    # immediately rather than waiting out a separate idle timeout of our
    # own just to reconfirm the same fact later.
    if map_size(queues) == 0 do
      {:stop, :normal, new_state}
    else
      {:noreply, new_state, idle_timeout_ms()}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    if map_size(state.queues) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, idle_timeout_ms()}
    end
  end

  @impl true
  def handle_info(:check_aggregate_budget, state) do
    queue_pids = Enum.filter(all_queue_pids(state), &safe_queue_active?/1)

    # A single active queue (or none) can't exceed an aggregate budget by
    # definition -- nothing to throttle.
    if length(queue_pids) >= 2 do
      ceiling = budget_ceiling(state)

      if ceiling > 0 do
        rates = Enum.map(queue_pids, &AccountQueue.get_rps/1)
        total = Enum.sum(rates)

        if total > ceiling do
          scale = ceiling / total

          Enum.zip(queue_pids, rates)
          |> Enum.each(fn {pid, rate} ->
            AccountQueue.update_rps(pid, max(rate * scale, @min_rps))
          end)
        end
      end
    end

    # Only keep rescheduling while there's still at least one queue --
    # otherwise this loop never stops, and every 3s message it sends itself
    # resets the GenServer receive-timeout that :timeout needs a real
    # 5-minute gap in to ever fire. handle_call({:enqueue, ...}) is what
    # restarts this once a queue exists again.
    if map_size(state.queues) > 0 do
      schedule_budget_check()
    end

    {:noreply, state, idle_timeout_ms()}
  end

  # ---- Private ----

  defp route_to_queue(action, job, state) do
    was_empty = map_size(state.queues) == 0

    queue_key =
      if state.account_queue_enabled do
        Job.queue_key(job)
      else
        @shared_queue_key
      end

    {queue_pid, new_state} = find_or_spawn_queue(queue_key, state)

    result =
      case action do
        :submit -> prepare_and_admit(queue_pid, job, new_state)
        :submit_internal -> AccountQueue.submit_internal(queue_pid, job)
        :prepare -> AccountQueue.prepare(queue_pid, job)
        :enqueue_prepared -> admit_prepared(queue_pid, job, new_state, :prepared)
        :admit_new -> admit_prepared(queue_pid, job, new_state, :new)
        :enqueue -> AccountQueue.enqueue(queue_pid, job)
      end

    # Restart the aggregate-budget check exactly when it would have stopped
    # itself -- a transition from genuinely idle to having real work again.
    if was_empty, do: schedule_budget_check()

    {:reply, result, new_state, idle_timeout_ms()}
  end

  defp prepare_and_admit(queue_pid, job, state) do
    case AccountQueue.prepare(queue_pid, job) do
      {:prepared, prepared_job} -> admit_prepared(queue_pid, prepared_job, state, :new)
      other -> other
    end
  end

  defp admit_prepared(queue_pid, job, state, mode) do
    case fair_admission(state, queue_pid) do
      {:allowed, _snapshot} ->
        case AccountQueue.enqueue_prepared(queue_pid, job) do
          :ok when mode == :new ->
            {:accepted, job}

          {:rejected, _reason, _limit, _current} = rejected ->
            IdempotentStore.delete_job(job)
            rejected

          other ->
            other
        end

      {:rejected, reason, snapshot} ->
        IdempotentStore.delete_job(job)
        {:rejected, reason, snapshot.max_backlog, snapshot.upstream_backlog - 1}
    end
  end

  defp fair_admission(state, queue_pid) do
    {active_queues, total_pending, queue_pending} = queue_counts(state, queue_pid)

    case FairAdmission.decide(
           queue_pending,
           total_pending,
           active_queues,
           state.max_backlog
         ) do
      {:allowed, snapshot} -> {:allowed, snapshot}
      {:rejected, reason, snapshot} -> {:rejected, reason, snapshot}
    end
  end

  defp queue_snapshot_for_job(state, job) do
    queue_key = if state.account_queue_enabled, do: Job.queue_key(job), else: @shared_queue_key

    queue_pid =
      if Cluster.standalone?(),
        do: Map.get(state.queues, queue_key),
        else: Cluster.lookup_account_queue(state.domain, queue_key)

    {active_queues, total_pending, queue_pending} = queue_counts(state, queue_pid, false)

    %{
      active_queues: active_queues,
      upstream_backlog: total_pending,
      queue_backlog: queue_pending,
      max_backlog: state.max_backlog,
      admission_pressure: FairAdmission.pressure(total_pending, state.max_backlog)
    }
  end

  defp queue_counts(state, queue_pid, include_incoming \\ true) do
    backlogs =
      state
      |> all_queue_pids()
      |> Enum.uniq()
      |> Enum.map(fn pid -> {pid, safe_queue_snapshot(pid).backlog} end)

    counts_from(state.account_queue_enabled, backlogs, queue_pid, include_incoming)
  end

  @doc """
  The fair-admission inputs {active_queues, total_pending, queue_pending}
  from each queue's backlog. Shared with EzthrottleLocal.Intake so the
  caller-side path counts exactly the way this actor does.
  """
  def counts_from(account_queue_enabled, backlogs, queue_pid, include_incoming) do
    total_pending = Enum.sum(Enum.map(backlogs, fn {_pid, b} -> b end))
    active_queues = Enum.count(backlogs, fn {_pid, b} -> b > 0 end)

    queue_pending =
      case Enum.find(backlogs, fn {pid, _b} -> pid == queue_pid end) do
        nil -> 0
        {_pid, b} -> b
      end

    active_queues =
      if include_incoming and queue_pending == 0, do: active_queues + 1, else: active_queues

    if account_queue_enabled do
      {max(active_queues, if(include_incoming, do: 1, else: 0)), total_pending, queue_pending}
    else
      active = if total_pending > 0 or include_incoming, do: 1, else: 0
      {active, total_pending, total_pending}
    end
  end

  defp safe_queue_snapshot(pid) do
    case AccountQueue.local_backlog(pid) do
      {:ok, backlog} -> %{backlog: backlog, active: backlog > 0}
      :unknown -> AccountQueue.snapshot(pid)
    end
  catch
    :exit, _reason -> %{backlog: 0, active: false}
  end

  defp safe_queue_active?(pid) do
    case AccountQueue.local_backlog(pid) do
      {:ok, backlog} -> backlog > 0
      :unknown -> AccountQueue.active?(pid)
    end
  catch
    :exit, _reason -> false
  end

  # On a standalone node this actor's own monitored map is authoritative.
  # A Syn lookup checks that the pid is alive, and is_process_alive on a
  # busy local queue waits behind that queue's mailbox.
  defp find_or_spawn_queue(queue_key, state) do
    case Cluster.standalone?() && Map.get(state.queues, queue_key) do
      pid when is_pid(pid) -> {pid, state}
      _ -> find_or_spawn_registered_queue(queue_key, state)
    end
  end

  defp find_or_spawn_registered_queue(queue_key, state) do
    case Cluster.lookup_account_queue(state.domain, queue_key) do
      nil -> spawn_registered_queue(queue_key, state)
      pid -> track_queue(queue_key, pid, state)
    end
  end

  defp spawn_registered_queue(queue_key, state) do
    opts = [
      queue_key: queue_key,
      upstream: state.domain,
      url_actor: self(),
      rps: state.rps,
      max_concurrent: state.max_concurrent,
      pool_pid: state.pool_pid,
      slow_start: state.slow_start_enabled,
      registry_name: Cluster.account_queue_via(state.domain, queue_key)
    ]

    case AccountQueue.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        track_queue(queue_key, pid, state)

      {:error, {:already_started, pid}} ->
        track_queue(queue_key, pid, state)

      {:error, reason} ->
        case Cluster.lookup_account_queue(state.domain, queue_key) do
          nil -> raise "failed to claim account queue #{inspect(queue_key)}: #{inspect(reason)}"
          winner -> track_queue(queue_key, winner, state)
        end
    end
  end

  defp track_queue(queue_key, pid, state) do
    if Map.get(state.queues, queue_key) != pid, do: Process.monitor(pid)
    EzthrottleLocal.Intake.register_queue(state.domain, queue_key, pid)
    {pid, %{state | queues: Map.put(state.queues, queue_key, pid)}}
  end

  defp publish(state) do
    EzthrottleLocal.Intake.publish_settings(
      state.domain,
      state.account_queue_enabled,
      state.max_backlog
    )

    state
  end

  defp schedule_budget_check do
    Process.send_after(self(), :check_aggregate_budget, @budget_check_ms)
  end

  defp all_queue_pids(state) do
    if Cluster.standalone?(),
      do: Map.values(state.queues),
      else: Cluster.account_queues_for_upstream(state.domain)
  end

  defp hydrate_cluster_state(state) do
    state.domain
    |> Cluster.url_actors_for_upstream()
    |> Enum.find_value(fn pid ->
      try do
        GenServer.call(pid, :cluster_snapshot, 2_000)
      catch
        :exit, _reason -> nil
      end
    end)
    |> case do
      nil -> state
      snapshot -> struct(state, snapshot)
    end
  end

  defp cluster_topic(domain), do: "url_actor:" <> Base.url_encode64(domain, padding: false)

  defp broadcast_cluster_state(state, field, value) do
    Phoenix.PubSub.broadcast_from(
      EzthrottleLocal.PubSub,
      self(),
      cluster_topic(state.domain),
      {:cluster_url_state, field, value}
    )
  end

  # How long this actor can sit genuinely idle before self-terminating --
  # same env var and default as AccountQueue.idle_timeout_ms/0 (one shared
  # knob for both levels of the same concept), overridable via
  # EZTHROTTLE_IDLE_TIMEOUT_SECONDS. EZTHROTTLE_IDLE_TIMEOUT_MS is accepted
  # as a compatibility fallback for older configs.
  defp idle_timeout_ms,
    do:
      env_seconds_as_ms(
        "EZTHROTTLE_IDLE_TIMEOUT_SECONDS",
        @default_idle_timeout_seconds,
        "EZTHROTTLE_IDLE_TIMEOUT_MS"
      )

  defp env_seconds_as_ms(seconds_key, default_seconds, legacy_ms_key) do
    case System.get_env(seconds_key) do
      nil -> env_int(legacy_ms_key, default_seconds * 1_000)
      "" -> env_int(legacy_ms_key, default_seconds * 1_000)
      val -> parsed_or_default(val, default_seconds) * 1_000
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> parsed_or_default(val, default)
    end
  end

  defp parsed_or_default(val, default) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  # Live pool capacity if pool-backed, otherwise the statically
  # configured RPS -- the total rate all of this worker's account queues
  # combined should never exceed.
  defp budget_ceiling(%{pool_pid: nil, rps: rps}), do: rps
  defp budget_ceiling(%{pool_pid: pid}), do: Pool.total_capacity(pid)
end
