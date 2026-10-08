defmodule EzthrottleLocal.AccountQueue do
  @moduledoc """
  GenServer per user_id + api_key scoped to a destination URL.
  Paces outbound requests at the configured RPS.
  Adapts RPS in real time via X-EZTHROTTLE-RPS response headers.
  Delivers results to the job's webhook_url.
  """

  use GenServer

  require Logger

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Metrics
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Pool
  alias EzthrottleLocal.Jitter
  alias EzthrottleLocal.Admission
  alias EzthrottleLocal.Cluster

  @default_idle_timeout_seconds 300
  @min_rps 0.5
  @position_broadcast_ms 2_000
  @max_retries 4
  @default_max_pending_per_user 10_000
  @dispatch_batch 64

  defstruct [
    :queue_key,
    :upstream,
    :url_actor,
    :pool_pid,
    rps: 2.0,
    configured_rps: 2.0,
    max_concurrent: 1,
    queue: :queue.new(),
    in_flight: 0,
    # Jobs in `queue`, kept here because :queue.len/1 walks the whole queue,
    # and it ran on every enqueue and dispatch: with a large backlog that
    # slowed dispatch to a crawl.
    queued: 0,
    # Whether a :broadcast_positions tick is pending. Without it, every time
    # the queue went from empty to non-empty a new 2s loop started while the
    # old one kept running, and under steady traffic hundreds piled up, each
    # walking the whole queue.
    positions_scheduled: false,
    last_request_at: 0,
    # Earliest execute_before among queued jobs (ms), nil when none has one.
    # expire_queued_jobs/1 runs on every :process_next; without this it
    # copied and filtered the whole queue each time, which grew
    # quadratically once a backlog built up.
    next_deadline: nil
  ]

  # ---- Public API ----

  def start_link(opts) do
    queue_key = Keyword.fetch!(opts, :queue_key)
    upstream = Keyword.fetch!(opts, :upstream)
    rps = Keyword.get(opts, :rps, 2.0)
    max_concurrent = Keyword.get(opts, :max_concurrent, 1)
    url_actor = Keyword.get(opts, :url_actor)
    pool_pid = Keyword.get(opts, :pool_pid)
    slow_start = Keyword.get(opts, :slow_start, false)

    state = %{
      queue_key: queue_key,
      upstream: upstream,
      url_actor: url_actor,
      rps: rps,
      max_concurrent: max_concurrent,
      pool_pid: pool_pid,
      slow_start: slow_start
    }

    case Keyword.get(opts, :registry_name) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  # Each queue's backlog (queued + in flight), kept by the queue itself so
  # fair admission can read local queues without calling every one of them
  # on every submission. Dispatch moves a job from queued to in flight, so
  # only enqueue, completion and expiry change it.
  @backlog_table :ez_queue_backlog

  @doc false
  def ensure_backlog_table do
    if :ets.whereis(@backlog_table) == :undefined do
      :ets.new(@backlog_table, [
        :named_table,
        :public,
        :set,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "This node's queue backlog from the shared table, or :unknown (remote or not tracked)."
  def local_backlog(pid) when node(pid) == node() do
    case :ets.lookup(@backlog_table, pid) do
      # No liveness check: is_process_alive on a busy local process waits
      # behind its mailbox. Callers only ask about queues they track by
      # monitor.
      [{^pid, backlog}] -> {:ok, max(backlog, 0)}
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  def local_backlog(_pid), do: :unknown

  defp backlog_add(0), do: :ok
  defp backlog_add(n), do: counter_add(self(), n) && :ok

  @doc """
  Adds n to a counter row in the backlog table and returns the new value.
  Keys are a queue pid (its backlog) or {pid, user_id} (that user's pending
  jobs in the queue). Also used by Intake to reserve before handing off.
  """
  def counter_add(key, n) do
    :ets.update_counter(@backlog_table, key, {2, n}, {key, 0})
  rescue
    ArgumentError -> 0
  end

  @doc "One fewer pending job for user_id in queue_pid; drops the row at zero."
  def user_release(_queue_pid, nil), do: :ok

  def user_release(queue_pid, user_id) do
    key = {queue_pid, user_id}

    if counter_add(key, -1) <= 0 do
      # delete_object only removes the row if it's still zero, so a
      # concurrent reservation isn't lost.
      :ets.delete_object(@backlog_table, {key, 0})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp user_pending(user_id) do
    case :ets.lookup(@backlog_table, {self(), user_id}) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Hands a job Intake already reserved a slot for to the queue."
  def handoff(pid, %Job{} = job), do: GenServer.cast(pid, {:enqueue_reserved, job})

  defp backlog_reset do
    :ets.insert(@backlog_table, {self(), 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp backlog_forget do
    :ets.delete(@backlog_table, self())
    :ets.match_delete(@backlog_table, {{self(), :_}, :_})
  rescue
    ArgumentError -> :ok
  end

  @doc "Persists and admits a new client submission on the queue-owning node."
  def submit(pid, %Job{} = job), do: GenServer.call(pid, {:submit, job}, 15_000)

  @doc "Persists internal work without applying the client-facing per-user ceiling."
  def submit_internal(pid, %Job{} = job),
    do: GenServer.call(pid, {:submit_internal, job}, 15_000)

  @doc "Persists a proxy request on the queue owner before its direct attempt."
  def prepare(pid, %Job{} = job), do: GenServer.call(pid, {:prepare, job}, 15_000)

  @doc "Queues a previously prepared proxy request, applying the per-user ceiling."
  def enqueue_prepared(pid, %Job{} = job),
    do: GenServer.call(pid, {:enqueue, job, true}, 15_000)

  @doc "Enqueues an already-persisted recovery job without reapplying client admission."
  def enqueue(pid, %Job{} = job), do: GenServer.call(pid, {:enqueue, job, false}, 15_000)

  def update_rps(pid, rps) do
    GenServer.cast(pid, {:update_rps, rps})
  end

  @doc "Current dispatch rate -- used by UrlActor's aggregate-budget check to read every sibling queue's live rate."
  def get_rps(pid), do: GenServer.call(pid, :get_rps)

  @doc """
  Whether this queue currently has real backlog (queued or in-flight work).
  Used by proxy mode to decide whether a domain should keep routing through
  the durable queue even after its circuit breaker's cooldown has elapsed --
  a cooldown timer alone doesn't know whether the backlog it caused has
  actually finished draining yet.
  """
  def active?(pid), do: GenServer.call(pid, :active?)

  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def update_max_concurrent(pid, max) do
    GenServer.cast(pid, {:update_max_concurrent, max})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{
        queue_key: queue_key,
        upstream: upstream,
        url_actor: url_actor,
        rps: rps,
        max_concurrent: max_concurrent,
        pool_pid: pool_pid,
        slow_start: slow_start
      }) do
    # A fresh queue's first dispatch has no prior response to read a pacing
    # signal from, so slow-start's starting point has to be decided up
    # front -- configured_rps keeps the real ceiling around so
    # maybe_update_rps/2's creep-back-up (below) has something to ramp
    # toward, since rps itself gets overwritten as pacing changes live.
    starting_rps = if slow_start, do: @min_rps, else: rps

    state = %__MODULE__{
      queue_key: queue_key,
      upstream: upstream,
      url_actor: url_actor,
      rps: starting_rps,
      configured_rps: rps,
      max_concurrent: max_concurrent,
      pool_pid: pool_pid
    }

    :ok = Cluster.join_upstream(upstream, self())
    backlog_reset()

    # No schedule_position_broadcast/0 here -- a fresh queue is always
    # immediately enqueued into (find_or_spawn_queue's one caller does both
    # in the same handler), and handle_call({:enqueue, ...}) below is what
    # actually starts the broadcast loop. Starting it here unconditionally
    # was the root cause of a real bug: the loop had no matching "stop
    # rescheduling once idle" check, so it ran forever regardless of
    # whether the queue ever had anything in it, which permanently blocked
    # this process's own idle-timeout from ever elapsing (see
    # handle_info(:broadcast_positions, ...) below for the other half of
    # the fix). Confirmed via aqueduct-runner: this is why drain mode could
    # never flush.
    {:ok, state, arm_idle_timeout()}
  end

  @impl true
  def handle_call({:submit, job}, _from, state) do
    case prepare_submission(job, true) do
      {:prepared, prepared_job} -> submit_inserted_job(state, prepared_job, true)
      other -> {:reply, other, state, arm_idle_timeout()}
    end
  end

  @impl true
  def handle_call({:submit_internal, job}, _from, state) do
    case prepare_submission(job, false) do
      {:prepared, prepared_job} -> submit_inserted_job(state, prepared_job, false)
      other -> {:reply, other, state, arm_idle_timeout()}
    end
  end

  @impl true
  def handle_call({:prepare, job}, _from, state) do
    {:reply, prepare_submission(job, true), state, arm_idle_timeout()}
  end

  @impl true
  def handle_call({:enqueue, job, enforce_limit}, _from, state) do
    case enqueue_job(state, job, enforce_limit) do
      {:ok, new_state} ->
        {:reply, :ok, new_state, arm_idle_timeout()}

      {:rejected, limit, current} ->
        {:reply, {:rejected, "user_queue", limit, current}, state, arm_idle_timeout()}
    end
  end

  @impl true
  def handle_call(
        {:job_done, user_id, rps_header, max_concurrent_header, account_queue_header,
         slow_start_header, max_backlog_header},
        _from,
        state
      ) do
    new_state =
      apply_job_done(
        state,
        rps_header,
        max_concurrent_header,
        account_queue_header,
        slow_start_header,
        max_backlog_header
      )

    send(self(), :process_next)
    {:reply, :ok, complete_user_job(new_state, user_id), arm_idle_timeout()}
  end

  @impl true
  def handle_call(:get_rps, _from, state),
    do: {:reply, state.rps, state, remaining_idle_timeout()}

  @impl true
  def handle_call(:active?, _from, state) do
    active? = not (:queue.is_empty(state.queue) and state.in_flight == 0)
    {:reply, active?, state, remaining_idle_timeout()}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    backlog = state.queued + state.in_flight
    {:reply, %{backlog: backlog, active: backlog > 0}, state, remaining_idle_timeout()}
  end

  @impl true
  def handle_cast({:enqueue_reserved, job}, state) do
    {:noreply, put_job(state, job), arm_idle_timeout()}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    safe_rps = max(rps, @min_rps)
    Metrics.flow_rate(state.upstream, safe_rps)
    {:noreply, %{state | rps: safe_rps}, arm_idle_timeout()}
  end

  @impl true
  def handle_cast({:update_max_concurrent, max}, state) do
    {:noreply, %{state | max_concurrent: max}, arm_idle_timeout()}
  end

  @impl true
  def handle_info(:process_next, state) do
    state = expire_queued_jobs(state)
    {:noreply, dispatch_batch(state, @dispatch_batch), arm_idle_timeout()}
  end

  @impl true
  def handle_info({:job_done, rps_header, max_concurrent_header}, state) do
    handle_info({:job_done, nil, rps_header, max_concurrent_header, nil, nil, nil}, state)
  end

  @impl true
  def handle_info({:job_done, rps_header, max_concurrent_header, account_queue_header}, state) do
    handle_info(
      {:job_done, nil, rps_header, max_concurrent_header, account_queue_header, nil, nil},
      state
    )
  end

  def handle_info(
        {:job_done, user_id, rps_header, max_concurrent_header, account_queue_header,
         slow_start_header},
        state
      ) do
    handle_info(
      {:job_done, user_id, rps_header, max_concurrent_header, account_queue_header,
       slow_start_header, nil},
      state
    )
  end

  @impl true
  def handle_info(
        {:job_done, user_id, rps_header, max_concurrent_header, account_queue_header,
         slow_start_header, max_backlog_header},
        state
      ) do
    new_state =
      apply_job_done(
        state,
        rps_header,
        max_concurrent_header,
        account_queue_header,
        slow_start_header,
        max_backlog_header
      )

    send(self(), :process_next)
    {:noreply, complete_user_job(new_state, user_id), arm_idle_timeout()}
  end

  @impl true
  def handle_info(:broadcast_positions, state) do
    state = %{state | positions_scheduled: false}
    # On a standalone node every subscriber is local, so skip jobs nobody is
    # streaming. Broadcasting for every queued job blocked this process for
    # long stretches once a backlog built, and submissions waited on it.
    standalone? = Cluster.standalone?()

    state.queue
    |> :queue.to_list()
    |> Enum.with_index(1)
    |> Enum.each(fn {job, position} ->
      if not standalone? or Registry.lookup(EzthrottleLocal.PubSub, "job:#{job.id}") != [],
        do: broadcast_position(job, position)
    end)

    # Only keep rescheduling while there's still something to report --
    # otherwise this loop never stops, and every 2s message it sends itself
    # resets the GenServer receive-timeout that :timeout below needs a real
    # 5-minute gap in to ever fire. handle_call({:enqueue, ...}) is what
    # restarts this once the queue has real work again.
    state =
      if :queue.is_empty(state.queue),
        do: state,
        else: schedule_position_broadcast(state)

    {:noreply, state, arm_idle_timeout()}
  end

  @impl true
  def handle_info(:timeout, state) do
    if :queue.is_empty(state.queue) and state.in_flight == 0 do
      retire_or_stay(state)
    else
      {:noreply, state, arm_idle_timeout()}
    end
  end

  # ---- Private ----

  # Dispatches until concurrency is full, the queue is empty, or `budget` is
  # spent. One job per :process_next message tied the dispatch rate to how
  # fast this mailbox drained: with many queued submissions ahead of each
  # :process_next, a queue allowed hundreds of concurrent requests sent only
  # a few dozen a second. A paced queue (rps below 1000) still sends one per
  # pass and sleeps between, as before.
  defp dispatch_batch(state, budget) do
    cond do
      budget <= 0 ->
        if state.in_flight < state.max_concurrent and not :queue.is_empty(state.queue),
          do: send(self(), :process_next)

        state

      state.in_flight >= state.max_concurrent ->
        state

      :queue.is_empty(state.queue) ->
        state

      true ->
        case dispatch_one(state) do
          {:dispatched, new_state} ->
            if trunc(1_000 / new_state.rps) == 0,
              do: dispatch_batch(new_state, budget - 1),
              else: new_state

          {:wait, new_state} ->
            new_state
        end
    end
  end

  defp dispatch_one(state) do
    case resolve_target(state) do
      :no_pool_members ->
        # Pool-backed queue with no live members yet. This can happen
        # during process restart before workers have had time to
        # heartbeat back in, so keep the head job queued and retry
        # later instead of turning temporary absence into terminal
        # failure.
        Process.send_after(self(), :process_next, no_pool_members_retry_ms())
        {:wait, state}

      {:ok, job, dispatch_url, member, remaining_queue} ->
        # Enforce RPS with jitter to prevent synchronized bursts across queues
        now = System.system_time(:millisecond)
        interval_ms = trunc(1_000 / state.rps)
        elapsed = now - state.last_request_at

        if elapsed < interval_ms do
          Process.sleep(Jitter.add_ms(interval_ms - elapsed))
        end

        new_state = %{
          state
          | queue: remaining_queue,
            queued: max(state.queued - 1, 0),
            in_flight: state.in_flight + 1,
            last_request_at: System.system_time(:millisecond)
        }

        Metrics.queue_depth(state.upstream, new_state.queued)

        parent = self()
        pool_pid = state.pool_pid
        member_id = member && member.id
        # Bind what the worker needs before spawning: a closure that mentions
        # `state.rps` captures all of `state`, including the queue, and a new
        # process starts with a copy of everything its closure captured. With
        # thousands of jobs queued, every dispatch copied the whole queue
        # (milliseconds each, and a copy held by every in-flight worker).
        rps = state.rps
        max_concurrent = state.max_concurrent
        queue_key = state.queue_key

        # spawn, not Task.start: Task.start reads this process's info for
        # caller metadata. Nothing awaits these.
        spawn(fn ->
          execute(job, dispatch_url, parent, rps, max_concurrent, queue_key, pool_pid, member_id)
        end)

        {:dispatched, new_state}
    end
  end

  # Unregister first, then look at the backlog. A caller that reserved on
  # this queue before the unregister shows up in the backlog, and we stay;
  # one that reserves after it sees the queue gone when it re-checks, rolls
  # back and finds another. Either way no job is handed to a queue that has
  # exited.
  defp retire_or_stay(state) do
    EzthrottleLocal.Intake.unregister_queue(state.upstream, state.queue_key, self())

    case local_backlog(self()) do
      {:ok, n} when n > 0 ->
        EzthrottleLocal.Intake.register_queue(state.upstream, state.queue_key, self())
        {:noreply, state, arm_idle_timeout()}

      _ ->
        backlog_forget()
        {:stop, :normal, state}
    end
  end

  defp broadcast_position(job, position) do
    Phoenix.PubSub.broadcast(
      EzthrottleLocal.PubSub,
      "job:#{job.id}",
      {:job_event,
       %{
         event: "position",
         job_id: job.id,
         position: position
       }}
    )
  end

  defp submit_inserted_job(state, job, enforce_limit) do
    case enqueue_job(state, job, enforce_limit) do
      {:ok, new_state} ->
        {:reply, {:accepted, job}, new_state, arm_idle_timeout()}

      {:rejected, limit, current} ->
        IdempotentStore.delete_job(job)

        {:reply, {:rejected, "user_queue", limit, current}, state, arm_idle_timeout()}
    end
  end

  @doc """
  Persists a submission and runs instance admission without touching the
  queue's state, so it can run in the caller's process. See
  AccountQueueRegistry.submit/2.
  """
  def prepare_submission(job, enforce_admission) do
    case IdempotentStore.check_or_insert(job) do
      {:duplicate, existing_id} ->
        {:duplicate, existing_id}

      :ok ->
        case if(enforce_admission, do: Admission.check(), else: :ok) do
          {:rejected, reason, limit, current} ->
            IdempotentStore.delete_job(job)
            {:rejected, reason, limit, current}

          :ok ->
            Metrics.job_queued(job.user_id, Metrics.upstream(job.url))
            {:prepared, job}
        end
    end
  end

  defp enqueue_job(state, job, enforce_limit) do
    current = user_pending(job.user_id)
    limit = max_pending_per_user()

    if enforce_limit and limit > 0 and current >= limit do
      {:rejected, limit, current}
    else
      backlog_add(1)
      if job.user_id, do: counter_add({self(), job.user_id}, 1)
      {:ok, put_job(state, job)}
    end
  end

  # Counters are already updated: by enqueue_job/3, or by Intake before the
  # :enqueue_reserved cast.
  defp put_job(state, job) do
    was_empty = :queue.is_empty(state.queue)
    new_queue = :queue.in(job, state.queue)
    state = %{state | next_deadline: earliest_deadline(state.next_deadline, job)}

    new_state = %{state | queue: new_queue, queued: state.queued + 1}

    Metrics.queue_depth(state.upstream, new_state.queued)
    # Restart the position-broadcast loop exactly when it would have
    # stopped itself (see handle_info(:broadcast_positions, ...)) -- a
    # transition from genuinely idle to having real work again.
    new_state = if was_empty, do: schedule_position_broadcast(new_state), else: new_state
    send(self(), :process_next)
    new_state
  end

  defp expire_queued_jobs(%{next_deadline: nil} = state), do: state

  defp expire_queued_jobs(%{next_deadline: deadline} = state) do
    if System.system_time(:millisecond) < deadline,
      do: state,
      else: scan_expired_jobs(state)
  end

  defp earliest_deadline(current, %Job{execute_before: before})
       when is_integer(before) and before > 0,
       do: if(current == nil or before < current, do: before, else: current)

  defp earliest_deadline(current, _job), do: current

  defp scan_expired_jobs(state) do
    {kept, expired} =
      state.queue
      |> :queue.to_list()
      |> Enum.split_with(&(not Job.execution_expired?(&1)))

    state = %{state | next_deadline: Enum.reduce(kept, nil, &earliest_deadline(&2, &1))}

    if expired == [] do
      state
    else
      backlog_add(-length(expired))
      state = %{state | queue: :queue.from_list(kept), queued: length(kept)}

      state =
        Enum.reduce(expired, state, fn job, current_state ->
          fail_expired_job(job, current_state.upstream)
          complete_user_job(current_state, job.user_id)
        end)

      Metrics.queue_depth(state.upstream, length(kept))
      state
    end
  end

  defp fail_expired_job(job, upstream) do
    reason = "execution_deadline_exceeded"
    payload = %{job_id: job.id, status: "failed", reason: reason}

    IdempotentStore.put_result(job.id, payload, :failed)
    IdempotentStore.update_status(job.id, :failed)
    Metrics.job_failed(job.user_id, upstream, reason)

    Phoenix.PubSub.broadcast(
      EzthrottleLocal.PubSub,
      "job:#{job.id}",
      {:job_event, Map.put(payload, :event, "failed")}
    )

    Task.start(fn ->
      maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, payload)
    end)
  end

  # Pool-backed queue: resolve via weighted selection. nil url/pool_pid on
  # a plain queue means dispatch straight to the job's own fixed url, same
  # as before pools existed.
  defp resolve_target(%{pool_pid: nil} = state) do
    {{:value, job}, remaining_queue} = :queue.out(state.queue)
    {:ok, job, job.url, nil, remaining_queue}
  end

  defp resolve_target(%{pool_pid: pool_pid} = state) do
    case Pool.pick(pool_pid) do
      nil ->
        :no_pool_members

      member ->
        {{:value, job}, remaining_queue} = :queue.out(state.queue)
        {:ok, job, member.address, member, remaining_queue}
    end
  end

  defp execute(
         %Job{} = job,
         dispatch_url,
         parent,
         flow_rate,
         max_concurrent,
         queue_key,
         pool_pid,
         member_id
       ) do
    started_at = System.monotonic_time(:millisecond)
    upstream = Metrics.upstream(job.pool_id || dispatch_url)

    Metrics.job_dispatched(job.user_id, upstream)

    Phoenix.PubSub.broadcast(
      EzthrottleLocal.PubSub,
      "job:#{job.id}",
      {:job_event,
       %{
         event: "dispatching",
         job_id: job.id
       }}
    )

    result =
      dispatch_with_retries(
        job,
        dispatch_url,
        flow_rate,
        max_concurrent,
        queue_key,
        pool_pid,
        member_id,
        0
      )

    case result do
      {:ok, %{status: status, body: body, headers: resp_headers}, successful_member_id} ->
        if pool_pid && successful_member_id,
          do: Pool.record_success(pool_pid, successful_member_id)

        rps = parse_rps_header(resp_headers) || EzthrottleLocal.Orca.rps(resp_headers)
        max_concurrent = parse_max_concurrent_header(resp_headers)
        account_queue = parse_account_queue_header(resp_headers)
        slow_start = parse_slow_start_header(resp_headers)
        max_backlog = parse_max_backlog_header(resp_headers)

        GenServer.call(
          parent,
          {:job_done, job.user_id, rps, max_concurrent, account_queue, slow_start, max_backlog}
        )

        completed_payload = %{
          job_id: job.id,
          status: "completed",
          response_status: status,
          body: body
        }

        IdempotentStore.put_result(job.id, completed_payload, :completed)
        IdempotentStore.update_status(job.id, :completed)

        Metrics.job_completed(
          job.user_id,
          upstream,
          System.monotonic_time(:millisecond) - started_at
        )

        Phoenix.PubSub.broadcast(
          EzthrottleLocal.PubSub,
          "job:#{job.id}",
          {:job_event,
           %{
             event: "completed",
             job_id: job.id,
             response_status: status,
             body: body
           }}
        )

        maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, %{
          job_id: job.id,
          status: "completed",
          response_status: status,
          body: body
        })

      {:error, reason, response} ->
        GenServer.call(parent, {:job_done, job.user_id, nil, nil, nil, nil, nil})

        failed_payload =
          %{
            job_id: job.id,
            status: "failed",
            reason: to_string(reason)
          }
          |> maybe_put_response(response)

        IdempotentStore.put_result(job.id, failed_payload, :failed)
        IdempotentStore.update_status(job.id, :failed)
        Metrics.job_failed(job.user_id, upstream, to_string(reason))

        failed_event = Map.put(failed_payload, :event, "failed")

        Phoenix.PubSub.broadcast(
          EzthrottleLocal.PubSub,
          "job:#{job.id}",
          {:job_event, failed_event}
        )

        maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, failed_payload)
    end
  end

  defp dispatch_with_retries(
         %Job{} = job,
         dispatch_url,
         flow_rate,
         max_concurrent,
         queue_key,
         pool_pid,
         member_id,
         attempt
       ) do
    if Job.execution_expired?(job) do
      {:error, "execution_deadline_exceeded", nil}
    else
      dispatch_with_retries_active(
        job,
        dispatch_url,
        flow_rate,
        max_concurrent,
        queue_key,
        pool_pid,
        member_id,
        attempt
      )
    end
  end

  defp dispatch_with_retries_active(
         job,
         dispatch_url,
         flow_rate,
         max_concurrent,
         queue_key,
         pool_pid,
         member_id,
         attempt
       ) do
    case make_request(job, dispatch_url, flow_rate, max_concurrent, queue_key, :infinity) do
      {:ok, %{status: status} = response} when status >= 500 ->
        if pool_pid && member_id, do: Pool.record_failure(pool_pid, member_id)

        if attempt < max_retries() do
          sleep_before_retry(attempt)

          case next_dispatch_target(pool_pid, dispatch_url) do
            {:ok, next_url, next_member_id} ->
              dispatch_with_retries(
                job,
                next_url,
                flow_rate,
                max_concurrent,
                queue_key,
                pool_pid,
                next_member_id,
                attempt + 1
              )

            :no_pool_members ->
              {:error, "no pool members registered", nil}
          end
        else
          {:error, "upstream returned #{status}", response}
        end

      {:ok, %{status: _status} = response} ->
        {:ok, response, member_id}

      {:error, reason} ->
        if pool_pid && member_id, do: Pool.record_failure(pool_pid, member_id)

        if attempt < max_retries() do
          sleep_before_retry(attempt)

          case next_dispatch_target(pool_pid, dispatch_url) do
            {:ok, next_url, next_member_id} ->
              dispatch_with_retries(
                job,
                next_url,
                flow_rate,
                max_concurrent,
                queue_key,
                pool_pid,
                next_member_id,
                attempt + 1
              )

            :no_pool_members ->
              {:error, "no pool members registered", nil}
          end
        else
          {:error, inspect(reason), nil}
        end
    end
  end

  defp next_dispatch_target(nil, dispatch_url), do: {:ok, dispatch_url, nil}

  defp next_dispatch_target(pool_pid, _dispatch_url) do
    case Pool.pick(pool_pid) do
      nil -> :no_pool_members
      member -> {:ok, member.address, member.id}
    end
  end

  defp maybe_put_response(payload, nil), do: payload

  defp maybe_put_response(payload, %{status: status, body: body}) do
    payload
    |> Map.put(:response_status, status)
    |> Map.put(:body, body)
  end

  # A webhook-delivery job (Job.webhook_delivery_job?/1) must never
  # enqueue its own webhook -- it flows through this same execute/8 path
  # as a regular job, so without this guard first, its own completion
  # would recursively enqueue another webhook delivery forever.
  defp maybe_deliver_webhook(_mode, %Job{webhook_url: url}, _payload) when url in [nil, ""],
    do: :ok

  defp maybe_deliver_webhook(:stream, _job, _payload), do: :ok

  defp maybe_deliver_webhook(_mode, job, payload) do
    AccountQueueRegistry.enqueue_webhook(job.id, job.user_id, job.webhook_url, payload)
  end

  defp max_retries,
    do: Application.get_env(:ezthrottle_local, :dispatch_max_retries, @max_retries)

  @doc "Maximum queued plus in-flight jobs accepted for one user; 0 disables the ceiling."
  def max_pending_per_user do
    case Integer.parse(
           System.get_env(
             "EZTHROTTLE_MAX_PENDING_PER_USER",
             Integer.to_string(@default_max_pending_per_user)
           )
         ) do
      {value, ""} when value >= 0 -> value
      _ -> @default_max_pending_per_user
    end
  end

  defp complete_user_job(state, user_id) do
    user_release(self(), user_id)
    state
  end

  defp no_pool_members_retry_ms,
    do: Application.get_env(:ezthrottle_local, :no_pool_members_retry_ms, 1_000)

  defp retry_backoff_ms(attempt), do: trunc(:math.pow(2, attempt) * 1_000)

  defp sleep_before_retry(attempt) do
    Process.sleep(
      Application.get_env(:ezthrottle_local, :dispatch_retry_ms, retry_backoff_ms(attempt))
      |> Jitter.add_ms()
    )
  end

  defp schedule_position_broadcast(%{positions_scheduled: true} = state), do: state

  defp schedule_position_broadcast(state) do
    Process.send_after(self(), :broadcast_positions, @position_broadcast_ms)
    %{state | positions_scheduled: true}
  end

  @doc """
  How long this queue can sit genuinely idle before self-terminating --
  300 seconds (5min) by default, overridable via
  EZTHROTTLE_IDLE_TIMEOUT_SECONDS. EZTHROTTLE_IDLE_TIMEOUT_MS is still
  accepted as a compatibility fallback for older configs.
  Exists mainly so contract tests (aqueduct-runner) don't have to burn 5+
  real minutes per drain-mode run; production should leave this at the
  default. Read live via System.get_env rather than Application config so
  a container-level env var (set the same way EZTHROTTLE_DRAIN_TIMER_SECONDS
  already is) takes effect with no code/config-file change.
  """
  def idle_timeout_ms,
    do:
      env_seconds_as_ms(
        "EZTHROTTLE_IDLE_TIMEOUT_SECONDS",
        @default_idle_timeout_seconds,
        "EZTHROTTLE_IDLE_TIMEOUT_MS"
      )

  # Read-only probes (active?/get_rps/snapshot) must not count as activity.
  # A GenServer reply with no timeout disables the idle timer, and one with a
  # fresh timeout restarts it, so UrlActor's 3s budget poll (and /health) kept
  # idle queues alive forever. Real work re-arms the deadline; probes reply
  # with whatever time is left.
  # The timeout is re-armed on every message, so it's read from the
  # environment once per queue process rather than each time.
  defp arm_idle_timeout do
    timeout =
      case Process.get(:idle_timeout_ms) do
        nil ->
          t = idle_timeout_ms()
          Process.put(:idle_timeout_ms, t)
          t

        t ->
          t
      end

    Process.put(:idle_deadline_ms, System.monotonic_time(:millisecond) + timeout)
    timeout
  end

  defp remaining_idle_timeout do
    case Process.get(:idle_deadline_ms) do
      nil -> arm_idle_timeout()
      deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
    end
  end

  defp env_seconds_as_ms(seconds_key, default_seconds, legacy_ms_key) do
    case System.get_env(seconds_key) do
      nil -> env_int(legacy_ms_key, default_seconds * 1_000)
      "" -> env_int(legacy_ms_key, default_seconds * 1_000)
      val -> parsed_or_default(val, default_seconds) * 1_000
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      val ->
        parsed_or_default(val, default)
    end
  end

  defp parsed_or_default(val, default) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc """
  Performs the actual synchronous HTTP dispatch to an upstream -- shared by
  the paced retry loop above (dispatch_with_retries/8, timeout: :infinity,
  its historical behavior) and EzthrottleLocal.Proxy's direct-attempt fast
  path (a short, caller-supplied timeout_ms, since the whole point there
  is failing fast rather than tying up the caller's connection). Exported
  (not defp) so Proxy can call it directly without duplicating the
  header-building/L8/ORCA logic below.
  """
  def make_request(
        %Job{} = job,
        dispatch_url,
        flow_rate,
        max_concurrent,
        queue_key,
        timeout \\ :infinity
      ) do
    %{total_jobs: total, queue_depth: depth} = EzthrottleLocal.IdempotentStore.counts()
    queue_snapshot = queue_load_snapshot(job)
    url = String.to_charlist(dispatch_url)
    account_queue_enabled = queue_key != :shared
    queue_key_header = if account_queue_enabled, do: to_string(queue_key), else: "shared"

    metric_headers = [
      {"x-aqueduct-total-jobs", to_string(total)},
      {"x-aqueduct-queue-depth", to_string(depth)},
      {"x-aqueduct-flow-rate", :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-aqueduct-active-queues", to_string(queue_snapshot.active_queues)},
      {"x-aqueduct-upstream-backlog", to_string(queue_snapshot.upstream_backlog)},
      {"x-aquifer-total-jobs", to_string(total)},
      {"x-aquifer-queue-depth", to_string(depth)},
      {"x-aquifer-flow-rate", :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-ezthrottle-current-total-jobs", to_string(total)},
      {"x-ezthrottle-current-queue-depth", to_string(depth)},
      {"x-ezthrottle-current-flow-rate",
       :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-ezthrottle-active-queues", to_string(queue_snapshot.active_queues)},
      {"x-ezthrottle-upstream-backlog", to_string(queue_snapshot.upstream_backlog)},
      {"x-ezthrottle-current-max-concurrent", to_string(max_concurrent)},
      {"x-ezthrottle-current-account-queue-enabled", to_string(account_queue_enabled)},
      {"x-ezthrottle-current-queue-key", queue_key_header},
      {"x-ezthrottle-current-queue-mode",
       if(account_queue_enabled, do: "account", else: "shared")}
    ]

    job_headers = Enum.map(job.headers, fn {k, v} -> {k, v} end)
    metric_headers = maybe_add_orca_opt_in(metric_headers, job_headers)
    {body, l8_headers} = maybe_seal_l8(job, dispatch_url)
    {sealed_type, l8_headers} = Map.pop(l8_headers, "Content-Type")
    content_type = sealed_type || "application/json"

    job_headers =
      if sealed_type,
        do: Enum.reject(job_headers, fn {k, _v} -> String.downcase(k) == "content-type" end),
        else: job_headers

    headers =
      Enum.map(job_headers ++ metric_headers ++ Map.to_list(l8_headers), fn {k, v} ->
        {to_string(k), to_string(v)}
      end)

    method =
      case String.upcase(job.method) do
        m when m in ["GET", "POST", "PUT", "PATCH", "DELETE"] -> m
        _ -> "GET"
      end

    has_content_type? = Enum.any?(headers, fn {k, _} -> String.downcase(k) == "content-type" end)

    {headers, body} =
      cond do
        method not in ["POST", "PUT", "PATCH"] -> {headers, nil}
        has_content_type? -> {headers, body}
        true -> {[{"content-type", content_type} | headers], body}
      end

    # Finch keeps a pool of persistent connections per host. :httpc's
    # default profile sent every request through one manager process and
    # kept few connections per host, which capped throughput on a single
    # busy upstream.
    request = Finch.build(method, to_string(url), headers, body)

    result =
      try do
        Finch.request(request, EzthrottleLocal.Finch,
          request_timeout: timeout,
          pool_timeout: 30_000
        )
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        resp_headers = charlist_headers_to_map(resp_headers)

        EzthrottleLocal.L8.Schemas.observe_hash(
          dispatch_url,
          pacing_header(resp_headers, "schema-hash")
        )

        {:ok,
         %{
           status: status,
           body: resp_body,
           headers: resp_headers
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp queue_load_snapshot(job) do
    AccountQueueRegistry.queue_snapshot(job)
  catch
    :exit, _reason -> %{active_queues: 0, upstream_backlog: 0}
  end

  # L8 signing and encryption prove EZThrottle's identity to (and keep the
  # payload private for) the *receiver* of a webhook -- they have no meaning
  # for forward dispatch to an arbitrary upstream API, so this only applies
  # when the job being dispatched is itself a webhook delivery (see
  # Job.webhook_delivery_job?/1). Mirrors Aquifer's account_queue.go makeRequest.
  defp maybe_seal_l8(%Job{webhook_url: url} = job, dispatch_url) when url in [nil, ""] do
    EzthrottleLocal.L8.ensure_trust(dispatch_url)
    content_type = Map.get(job.headers || %{}, "Content-Type", "application/json")

    {:ok, body, headers} =
      EzthrottleLocal.L8.seal_delivery(dispatch_url, job.body || "", content_type)

    {body, headers}
  end

  defp maybe_seal_l8(job, _dispatch_url), do: {job.body || "", %{}}

  # Opts every dispatch into ORCA reporting by default, unless the caller
  # already set the format header explicitly -- mirrors Aquifer's
  # account_queue.go, which sends this on every dispatch too.
  #
  # Lowercase "text", not "TEXT": vLLM accepts either (metrics_format.lower()
  # in orca_metrics.py), but Triton's ORCA support (src/orca_http.cc,
  # orca_type == "text") is case-sensitive and only accepts the lowercase
  # literal -- "TEXT" makes Triton log an error and write no header at all.
  defp maybe_add_orca_opt_in(metric_headers, job_headers) do
    orca_header = EzthrottleLocal.Orca.request_header_name()

    already_set? =
      Enum.any?(job_headers, fn {k, _v} -> String.downcase(k) == orca_header end)

    if already_set? do
      metric_headers
    else
      [{orca_header, "text"} | metric_headers]
    end
  end

  defp charlist_headers_to_map(headers) do
    Enum.reduce(headers, %{}, fn {k, v}, acc ->
      Map.put(acc, k |> to_string() |> String.downcase(), to_string(v))
    end)
  end

  @doc """
  Reads X-Aqueduct-<name> first, falling back to X-EZThrottle-<name> — same
  dual-namespace precedence Aquifer uses (X-Aqueduct-* is the protocol name,
  X-Aquifer-*/X-EZThrottle-* are product aliases), so a backend speaking
  either protocol's headers is understood. Public so Proxy can reuse it for
  the same inbound-signal parsing on the direct-attempt path.
  """
  def pacing_header(headers, name) when is_map(headers) do
    case Map.get(headers, "x-aqueduct-#{name}") do
      nil -> Map.get(headers, "x-ezthrottle-#{name}")
      val -> val
    end
  end

  def pacing_header(_headers, _name), do: nil

  defp parse_rps_header(headers) do
    case pacing_header(headers, "rps") do
      nil ->
        nil

      val ->
        case Float.parse(val) do
          {rps, _} -> rps
          :error -> nil
        end
    end
  end

  defp parse_max_concurrent_header(headers) do
    case pacing_header(headers, "max-concurrent") do
      nil ->
        nil

      val ->
        case Integer.parse(val) do
          {max, _} -> max
          :error -> nil
        end
    end
  end

  defp parse_account_queue_header(headers) do
    case pacing_header(headers, "account-queue") do
      nil ->
        nil

      val ->
        case val |> String.trim() |> String.downcase() do
          mode when mode in ["enabled", "disabled"] -> mode
          _ -> nil
        end
    end
  end

  defp parse_slow_start_header(headers) do
    case pacing_header(headers, "slow-start") do
      nil ->
        nil

      val ->
        case val |> String.trim() |> String.downcase() do
          "true" -> true
          "false" -> false
          _ -> nil
        end
    end
  end

  defp parse_max_backlog_header(headers) do
    case pacing_header(headers, "max-backlog") do
      nil ->
        nil

      val ->
        case Integer.parse(val) do
          {max_backlog, ""} when max_backlog >= 0 -> max_backlog
          _ -> nil
        end
    end
  end

  # No explicit rate signal on this response -- creep back up toward the
  # configured ceiling instead of staying wherever a previous throttle (or
  # slow start) left it. Mirrors Aquifer's account_queue.go run() (the
  # `else if rps < configuredRPS` branch); this is also the actual ramp
  # mechanism slow start depends on, not new logic invented for it.
  defp maybe_update_rps(%{rps: rps, configured_rps: configured_rps} = state, nil)
       when rps < configured_rps do
    %{state | rps: min(rps * 1.05, configured_rps)}
  end

  defp maybe_update_rps(state, nil), do: state
  defp maybe_update_rps(state, rps), do: %{state | rps: max(rps, @min_rps)}

  defp maybe_update_max_concurrent(state, nil), do: state
  defp maybe_update_max_concurrent(state, max), do: %{state | max_concurrent: max}

  defp apply_job_done(
         state,
         rps_header,
         max_concurrent_header,
         account_queue_header,
         slow_start_header,
         max_backlog_header
       ) do
    maybe_update_account_queue_mode(state, account_queue_header)
    maybe_propagate_slow_start(state, slow_start_header)
    maybe_propagate_max_backlog(state, max_backlog_header)

    new_state =
      state
      |> maybe_update_rps(rps_header)
      |> maybe_update_max_concurrent(max_concurrent_header)
      |> Map.put(:in_flight, max(state.in_flight - 1, 0))

    if state.in_flight > 0, do: backlog_add(-1)

    if new_state.rps != state.rps do
      Metrics.flow_rate(state.upstream, new_state.rps)
    end

    new_state
  end

  defp maybe_update_account_queue_mode(%{url_actor: nil}, _mode), do: :ok
  defp maybe_update_account_queue_mode(_state, nil), do: :ok

  defp maybe_update_account_queue_mode(%{url_actor: url_actor}, mode) do
    GenServer.call(url_actor, {:account_queue_header, mode})
    :ok
  end

  # Applies to the *next* new queue created for this domain, not this one
  # (which is already running -- its starting rate already happened) and
  # not retroactively. Mirrors Aquifer's URLWorker.slowStart/onSlowStartSignal.
  defp maybe_propagate_slow_start(%{url_actor: nil}, _enabled), do: :ok
  defp maybe_propagate_slow_start(_state, nil), do: :ok

  defp maybe_propagate_slow_start(%{url_actor: url_actor}, enabled) do
    GenServer.call(url_actor, {:slow_start_header, enabled})
    :ok
  end

  defp maybe_propagate_max_backlog(%{url_actor: nil}, _max_backlog), do: :ok
  defp maybe_propagate_max_backlog(_state, nil), do: :ok

  defp maybe_propagate_max_backlog(%{url_actor: url_actor}, max_backlog) do
    GenServer.call(url_actor, {:max_backlog_header, max_backlog})
    :ok
  end
end
