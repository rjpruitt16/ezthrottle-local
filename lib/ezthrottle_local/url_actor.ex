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
  alias EzthrottleLocal.Job
  alias EzthrottleLocal.Pool

  @default_idle_timeout_ms 300_000
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
    breaker_until_ms: nil
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
  Opens the breaker for cooldown_ms. No separate half-open state is
  needed: once the cooldown elapses, breaker_open?/1 naturally returns
  false again, so the next request is itself a real probe against the
  live upstream -- success leaves the breaker closed, a repeat overload
  signal re-trips it via another trip_breaker/2 call. Mirrors Aquifer's
  URLWorker.TripBreaker.
  """
  def trip_breaker(pid, cooldown_ms) do
    GenServer.cast(pid, {:trip_breaker, cooldown_ms})
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

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{url_key: url_key, domain: domain, pool_pid: pool_pid}) do
    default_rps = Application.get_env(:ezthrottle_local, :default_rps, 2.0)
    account_queue_enabled = Application.get_env(:ezthrottle_local, :account_queue_enabled, false)

    state = %__MODULE__{
      url_key: url_key,
      domain: domain,
      pool_pid: pool_pid,
      rps: default_rps,
      account_queue_enabled: account_queue_enabled
    }

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
    was_empty = map_size(state.queues) == 0

    queue_key =
      if state.account_queue_enabled do
        Job.queue_key(job)
      else
        @shared_queue_key
      end

    {queue_pid, new_state} = find_or_spawn_queue(queue_key, state)
    AccountQueue.enqueue(queue_pid, job)
    # Restart the aggregate-budget check exactly when it would have stopped
    # itself -- a transition from genuinely idle to having real work again.
    if was_empty, do: schedule_budget_check()

    {:reply, :ok, new_state, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:account_queue_header, "enabled"}, _from, state) do
    {:reply, :ok, %{state | account_queue_enabled: true}, idle_timeout_ms()}
  end

  @impl true
  def handle_call({:account_queue_header, "disabled"}, _from, state) do
    {:reply, :ok, %{state | account_queue_enabled: false}, idle_timeout_ms()}
  end

  @impl true
  def handle_call(:breaker_open?, _from, state) do
    open? =
      case state.breaker_until_ms do
        nil -> false
        until_ms -> System.monotonic_time(:millisecond) < until_ms
      end

    {:reply, open?, state, idle_timeout_ms()}
  end

  @impl true
  def handle_call(:queue_active?, _from, state) do
    active? = state.queues |> Map.values() |> Enum.any?(&AccountQueue.active?/1)
    {:reply, active?, state, idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    Enum.each(state.queues, fn {_key, pid} ->
      AccountQueue.update_rps(pid, rps)
    end)

    {:noreply, %{state | rps: rps}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:update_max_concurrent, max}, state) do
    Enum.each(state.queues, fn {_key, pid} ->
      AccountQueue.update_max_concurrent(pid, max)
    end)

    {:noreply, %{state | max_concurrent: max}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast(:enable_account_queue, state) do
    {:noreply, %{state | account_queue_enabled: true}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast(:disable_account_queue, state) do
    {:noreply, %{state | account_queue_enabled: false}, idle_timeout_ms()}
  end

  @impl true
  def handle_cast({:trip_breaker, cooldown_ms}, state) do
    until_ms = System.monotonic_time(:millisecond) + cooldown_ms
    {:noreply, %{state | breaker_until_ms: until_ms}, idle_timeout_ms()}
  end

  @impl true
  def handle_info({:account_queue_header, "enabled"}, state) do
    {:noreply, %{state | account_queue_enabled: true}, idle_timeout_ms()}
  end

  @impl true
  def handle_info({:account_queue_header, "disabled"}, state) do
    {:noreply, %{state | account_queue_enabled: false}, idle_timeout_ms()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    queues = Enum.reject(state.queues, fn {_key, p} -> p == pid end) |> Map.new()
    {:noreply, %{state | queues: queues}, idle_timeout_ms()}
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
    queue_pids = Map.values(state.queues)

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

  defp find_or_spawn_queue(queue_key, state) do
    case Map.get(state.queues, queue_key) do
      nil ->
        {:ok, pid} =
          AccountQueue.start_link(
            queue_key: queue_key,
            upstream: state.domain,
            url_actor: self(),
            rps: state.rps,
            max_concurrent: state.max_concurrent,
            pool_pid: state.pool_pid
          )

        Process.monitor(pid)
        new_state = %{state | queues: Map.put(state.queues, queue_key, pid)}
        {pid, new_state}

      pid ->
        {pid, state}
    end
  end

  defp schedule_budget_check do
    Process.send_after(self(), :check_aggregate_budget, @budget_check_ms)
  end

  # How long this actor can sit genuinely idle before self-terminating --
  # same env var and default as AccountQueue.idle_timeout_ms/0 (one shared
  # knob for both levels of the same concept), overridable via
  # EZTHROTTLE_IDLE_TIMEOUT_MS so contract tests don't have to burn 5+ real
  # minutes per level per drain-mode run.
  defp idle_timeout_ms, do: env_int("EZTHROTTLE_IDLE_TIMEOUT_MS", @default_idle_timeout_ms)

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> case Integer.parse(val) do
        {n, _} -> n
        :error -> default
      end
    end
  end

  # Live pool capacity if pool-backed, otherwise the statically
  # configured RPS -- the total rate all of this worker's account queues
  # combined should never exceed.
  defp budget_ceiling(%{pool_pid: nil, rps: rps}), do: rps
  defp budget_ceiling(%{pool_pid: pid}), do: Pool.total_capacity(pid)
end
