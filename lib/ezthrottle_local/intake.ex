defmodule EzthrottleLocal.Intake do
  @moduledoc """
  The standalone submission path, run in the caller's process.

  Before this, every job for a domain went through that domain's UrlActor
  (one process): admission, a call into the AccountQueue to enqueue, and
  another call for the response headers. Each waited for the one before, so
  one domain's throughput was capped by one process no matter how many cores
  the machine had.

  Here the caller finds its queue, reserves a backlog slot, decides fair
  admission and the per-user limit, and hands the job over with a cast. The
  shared state it needs lives in ETS:

    * `:ez_queues`: `{{domain, queue_key}, pid}` per queue, and
      `{{:settings, domain}, account_queue_enabled, max_backlog}` per domain.
      The UrlActor writes both.
    * `:ez_queue_backlog` (see AccountQueue): `{pid, backlog}` per queue and
      `{{pid, user_id}, pending}` per user.

  A reservation counts the job first and decides second, undoing the count on
  rejection, so concurrent submissions see each other. The UrlActor still
  spawns queues, holds the breaker and applies rate changes; it's just off
  the per-job path.

  Clustered nodes don't use this path (see Cluster.standalone?/0).
  """

  alias EzthrottleLocal.{AccountQueue, FairAdmission, Job, UrlActor}

  @queues :ez_queues
  @max_attempts 10

  def ensure_tables do
    if :ets.whereis(@queues) == :undefined do
      :ets.new(@queues, [:named_table, :public, :set, read_concurrency: true])
    end

    AccountQueue.ensure_backlog_table()
  rescue
    ArgumentError -> :ok
  end

  @doc "Registers a queue so callers can find it (UrlActor, on spawn)."
  def register_queue(domain, queue_key, pid),
    do: safe(fn -> :ets.insert(@queues, {{domain, queue_key}, pid}) end)

  @doc "Removes a queue's entry only if it still points at pid."
  def unregister_queue(domain, queue_key, pid),
    do: safe(fn -> :ets.delete_object(@queues, {{domain, queue_key}, pid}) end)

  def publish_settings(domain, account_queue_enabled, max_backlog),
    do:
      safe(fn ->
        :ets.insert(@queues, {{:settings, domain}, account_queue_enabled, max_backlog})
      end)

  @doc """
  Reserves, decides and hands off an already-persisted job. mode is :new
  (fair admission and the per-user limit apply) or :internal (webhook
  deliveries: neither applies). Returns :ok or
  {:rejected, reason, limit, current}.
  """
  def admit(actor, domain, %Job{} = job, mode, replace_actor, attempt \\ 1) do
    case locate(actor, domain, job) do
      {:ok, enabled, max_backlog, key, queue} ->
        reserve(
          actor,
          domain,
          job,
          mode,
          replace_actor,
          attempt,
          enabled,
          max_backlog,
          key,
          queue
        )

      # The domain's actor retired (no queues left) after we looked it up.
      # Nothing is reserved yet; get a live one and start over.
      :actor_gone when attempt < @max_attempts ->
        backoff(attempt)
        admit(replace_actor.(actor), domain, job, mode, replace_actor, attempt + 1)

      :actor_gone ->
        {:rejected, "queue_unavailable", 0, 0}
    end
  end

  defp locate(actor, domain, job) do
    {enabled, max_backlog} = settings(actor, domain)
    key = if enabled, do: Job.queue_key(job), else: :shared
    {:ok, enabled, max_backlog, key, find_queue(actor, domain, key)}
  catch
    :exit, {:noproc, _} -> :actor_gone
    :exit, {:normal, _} -> :actor_gone
    :exit, {:shutdown, _} -> :actor_gone
  end

  defp reserve(actor, domain, job, mode, replace_actor, attempt, enabled, max_backlog, key, queue) do
    backlog_add(queue, 1)
    user_before = user_add(queue, job.user_id, 1) - 1

    decision =
      if mode == :internal,
        do: :allowed,
        else: decide(domain, queue, enabled, max_backlog, user_before)

    cond do
      decision != :allowed ->
        rollback(queue, job.user_id)
        decision

      registered?(domain, key, queue) ->
        # Record the user's load here, before the caller gets its response,
        # not when the queue processes the cast: the next submission's
        # webhook-backlog admission has to see it.
        EzthrottleLocal.UserLoad.add(job)
        AccountQueue.handoff(queue, job)
        :ok

      # The queue retired between lookup and reservation; it saw no backlog
      # and exited. Give the slot back and find (or spawn) a live one.
      attempt < @max_attempts ->
        rollback(queue, job.user_id)
        backoff(attempt)
        admit(actor, domain, job, mode, replace_actor, attempt + 1)

      true ->
        rollback(queue, job.user_id)
        {:rejected, "queue_unavailable", 0, 0}
    end
  end

  # A retiring queue unregisters before it exits, and until the actor sees
  # its exit the actor can still hand it out. Retrying immediately could
  # use up every attempt inside that window and turn a routine retirement
  # into a 429, so back off briefly (1, 4, 9 ... capped at 50ms).
  defp backoff(attempt), do: Process.sleep(min(attempt * attempt, 50))

  @doc "Queue headers for a response, from ETS (UrlActor.queue_snapshot/2's shape)."
  def snapshot(actor, domain, %Job{} = job) do
    {enabled, max_backlog} = settings(actor, domain)
    key = if enabled, do: Job.queue_key(job), else: :shared
    queue = lookup_queue(domain, key)
    {active, total, mine} = UrlActor.counts_from(enabled, domain_backlogs(domain), queue, false)

    %{
      active_queues: active,
      upstream_backlog: total,
      queue_backlog: mine,
      max_backlog: max_backlog,
      admission_pressure: FairAdmission.pressure(total, max_backlog)
    }
  end

  # ---- fair admission, same inputs UrlActor used ----

  defp decide(domain, queue, enabled, max_backlog, user_before) do
    # Our own reservation is already counted; decide as if it weren't, the
    # way the UrlActor counted backlog before enqueueing.
    backlogs =
      Enum.map(domain_backlogs(domain), fn
        {^queue, b} -> {queue, b - 1}
        other -> other
      end)

    {active, total, mine} = UrlActor.counts_from(enabled, backlogs, queue, true)

    case FairAdmission.decide(mine, total, active, max_backlog) do
      {:allowed, _snapshot} ->
        limit = AccountQueue.max_pending_per_user()

        if limit > 0 and user_before >= limit,
          do: {:rejected, "user_queue", limit, user_before},
          else: :allowed

      {:rejected, reason, snapshot} ->
        {:rejected, reason, snapshot.max_backlog, snapshot.upstream_backlog - 1}
    end
  end

  defp domain_backlogs(domain) do
    @queues
    |> :ets.match({{domain, :_}, :"$1"})
    |> Enum.map(fn [pid] ->
      case AccountQueue.local_backlog(pid) do
        {:ok, b} -> {pid, b}
        :unknown -> {pid, 0}
      end
    end)
  end

  # ---- lookups ----

  defp settings(actor, domain) do
    case :ets.lookup(@queues, {:settings, domain}) do
      [{_, enabled, max_backlog}] ->
        {enabled, max_backlog}

      [] ->
        UrlActor.publish_settings(actor)
        settings_after_publish(domain)
    end
  end

  defp settings_after_publish(domain) do
    case :ets.lookup(@queues, {:settings, domain}) do
      [{_, enabled, max_backlog}] -> {enabled, max_backlog}
      [] -> {false, FairAdmission.max_pending_per_upstream()}
    end
  end

  defp find_queue(actor, domain, key) do
    case lookup_queue(domain, key) do
      nil -> UrlActor.ensure_queue(actor, key)
      pid -> pid
    end
  end

  defp lookup_queue(domain, key) do
    case :ets.lookup(@queues, {domain, key}) do
      [{_, pid}] -> pid
      [] -> nil
    end
  end

  defp registered?(domain, key, queue), do: lookup_queue(domain, key) == queue

  # ---- counters (rows live in AccountQueue's backlog table) ----

  defp backlog_add(queue, n), do: AccountQueue.counter_add(queue, n)
  defp user_add(queue, user_id, n), do: AccountQueue.counter_add({queue, user_id}, n)

  defp rollback(queue, user_id) do
    backlog_add(queue, -1)
    AccountQueue.user_release(queue, user_id)
  end

  defp safe(fun) do
    fun.()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
