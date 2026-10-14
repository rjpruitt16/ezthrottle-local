# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.IdempotentStore do
  @moduledoc """
  The job store: idempotency keys and full job structs with TTL, in RocksDB
  (see Spillway.Store). Column families:
  - keys         - hashed idempotent_key => {job_id, expires_at, status};
                   prevents duplicate execution
  - jobs         - job_id => {job, expires_at, status}, for status lookup
                   and recovery after a restart
  - results      - job_id => {result, expires_at}, terminal payloads for polling
  - delivery     - job_id => delivery mode
  - drain_events - job_id => {sequence, key_hash, status, recorded_at},
                   terminal events until drain mode acknowledges them
  - expiry       - <<expires_at::64, job_id>>, every job ordered by expiry

  Raw client keys are never stored - they are hashed before insertion.
  TTL defaults to 24 hours and is configurable via :idempotent_ttl.

  check_or_insert/1 holds a per-key lock (the key gate) while it reads the
  key and writes the job, so two concurrent requests with the same key
  can't both insert. A job's rows are written as one atomic batch.
  """

  use GenServer

  require Logger

  alias Spillway.Job
  alias Spillway.Cluster
  alias Spillway.Store

  # Expired jobs are found through the expiry column family, ordered by
  # expiry, and deleted a batch at a time.
  @cleanup_interval_ms 10_000
  @expire_batch 2_000

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Opens the store and loads the drain sequence. Must be called before any
  other function here. Safe to call on every boot.
  """
  def ensure_schema! do
    Store.open!()
    seed_drain_sequence()
    :ok
  end

  @doc "Always \"rocksdb\"; reported on GET /health."
  def storage, do: "rocksdb"

  defp expiry_key(expires_at, job_id), do: <<expires_at::unsigned-64, job_id::binary>>

  defp index_put_op(expires_at, job_id), do: {:put, :expiry, expiry_key(expires_at, job_id), nil}
  defp index_delete_op(expires_at, job_id), do: {:delete, :expiry, expiry_key(expires_at, job_id)}

  defp read_job_row(job_id) do
    case Store.get(:jobs, job_id) do
      {:ok, {job, expires_at, status}} -> {job, expires_at, status}
      :not_found -> nil
    end
  end

  defp read_key_row(hashed) do
    case Store.get(:keys, hashed) do
      {:ok, {job_id, expires_at, status}} -> {job_id, expires_at, status}
      :not_found -> nil
    end
  end

  # Deletes the key row only if it still points at job_id: a newer job may
  # own the key by now.
  defp key_delete_ops(hashed, job_id) do
    case read_key_row(hashed) do
      {^job_id, _, _} -> [{:delete, :keys, hashed}]
      _ -> []
    end
  end

  @doc "The id of the job already holding this job's idempotency key, or nil."
  def existing_job_id(%Job{} = job) do
    hashed = hash_key(job)

    case read_key_row(hashed) do
      {job_id, _expires_at, _status} -> job_id
      nil -> nil
    end
  end

  @doc """
  Check if an idempotent key already exists.
  If not, insert the full job into both tables.
  Returns :ok for new jobs or {:duplicate, existing_job_id} for known keys.
  """
  def check_or_insert(%Job{} = job) do
    hashed = hash_key(job)
    expires_at = System.system_time(:millisecond) + ttl_ms(:queued)

    result =
      with_key_gate(hashed, fn ->
        case read_key_row(hashed) do
          {existing_id, _expires_at, _status} ->
            {:duplicate, existing_id}

          nil ->
            Store.write([
              {:put, :keys, hashed, {job.id, expires_at, :queued}},
              {:put, :jobs, job.id, {job, expires_at, :queued}},
              index_put_op(expires_at, job.id)
            ])

            :ok
        end
      end)

    case result do
      :ok ->
        count_insert(:queued)
        register_job_owner(job.id)

      {:duplicate, existing_id} ->
        register_job_owner(existing_id)
    end

    result
  end

  # The key gate: a lock per idempotency key, held only while one insert
  # checks the key and writes. :ets.insert_new is atomic, so of any
  # concurrent inserts for one key exactly one holds it; the others wait,
  # then find its row and report a duplicate. The table is owned by
  # Spillway.Store's process.
  @key_gate :idempotent_key_gate

  defp with_key_gate(hashed, fun) do
    gate_lock(hashed)

    try do
      fun.()
    after
      gate_unlock(hashed)
    end
  end

  # The lock records its holder, so a lock left by a process that died
  # holding it (killed between lock and unlock) is taken over instead of
  # blocking that key forever.
  defp gate_lock(hashed) do
    unless :ets.insert_new(@key_gate, {hashed, self()}) do
      case :ets.lookup(@key_gate, hashed) do
        [{^hashed, holder} = entry] when is_pid(holder) ->
          unless Process.alive?(holder), do: :ets.delete_object(@key_gate, entry)

        _ ->
          :ok
      end

      :erlang.yield()
      gate_lock(hashed)
    end
  end

  defp gate_unlock(hashed), do: :ets.delete_object(@key_gate, {hashed, self()})

  @doc false
  def create_key_gate do
    if :ets.whereis(@key_gate) == :undefined do
      :ets.new(@key_gate, [
        :named_table,
        :public,
        :set,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Removes a job's rows from both tables outright. Used when a freshly
  inserted, non-duplicate job is rejected by admission control —
  check_or_insert already wrote both rows before duplicate status was
  known, so a rejected job must be deleted here or it would sit as a
  ghost "queued" row that never dispatches, and a retry of the same
  idempotent key would forever see it as a "duplicate" pointing at a job
  that doesn't really exist.
  """
  def delete_job(%Job{} = job) do
    route_job(job.id, {:delete_job, job}, fn -> delete_job_local(job) end)
  end

  @doc """
  Undoes check_or_insert/1 for a job admission refused before it was ever
  queued. It mirrors the insert: dirty operations, no transaction. The key
  row is deleted only if it still points at this job.
  delete_job/1's synced transaction cost as much as accepting a job, so
  under overload every refusal added to the load that caused it (the soak
  test found refusals taking ~12% of a saturated node).
  """
  def discard_refused(%Job{} = job) do
    route_job(job.id, {:discard_refused, job}, fn -> discard_refused_local(job) end)
  end

  defp discard_refused_local(%Job{} = job), do: remove_job(job)

  defp delete_job_local(%Job{} = job), do: remove_job(job)

  defp remove_job(%Job{} = job) do
    hashed = hash_key(job)
    job_id = job.id

    {old_status, index_ops} =
      case read_job_row(job_id) do
        {_, expires_at, status} -> {status, [index_delete_op(expires_at, job_id)]}
        nil -> {nil, []}
      end

    Store.write(
      index_ops ++
        [{:delete, :jobs, job_id}, {:delete, :results, job_id}, {:delete, :delivery, job_id}] ++
        key_delete_ops(hashed, job_id)
    )

    if old_status, do: count_delete(old_status)
    unregister_job_owner(job_id)
    :ok
  end

  @doc """
  Update the status of a job by job_id in both tables.
  """
  def update_status(job_id, status) do
    route_job(job_id, {:update_status, job_id, status}, fn ->
      update_status_local(job_id, status)
    end)
  end

  defp update_status_local(job_id, status) do
    case read_job_row(job_id) do
      {job, old_expires, old_status} ->
        new_expires = System.system_time(:millisecond) + ttl_ms(status)
        hashed = hash_key(job)

        key_ops =
          case read_key_row(hashed) do
            {^job_id, _key_expires, _} -> [{:put, :keys, hashed, {job_id, new_expires, status}}]
            _ -> []
          end

        Store.write(
          [
            {:put, :jobs, job_id, {job, new_expires, status}},
            index_put_op(new_expires, job_id)
          ] ++
            if(old_expires != new_expires, do: [index_delete_op(old_expires, job_id)], else: []) ++
            key_ops ++ drain_event_ops(job, hashed, status)
        )

        count_move(old_status, status)
        :ok

      nil ->
        :error
    end
  end

  @doc """
  Persists a failed attempt: stores the job with its new attempt count and
  returns it to :queued, so a restart during the retry backoff recovers it
  without resetting the count.
  """
  def record_retry(%Job{} = job) do
    route_job(job.id, {:record_retry, job}, fn -> record_retry_local(job) end)
  end

  defp record_retry_local(%Job{} = job) do
    expires_at = System.system_time(:millisecond) + ttl_ms(:queued)

    old_index =
      case read_job_row(job.id) do
        {_, old_expires, _} when old_expires != expires_at ->
          [index_delete_op(old_expires, job.id)]

        _ ->
          []
      end

    Store.write(
      old_index ++
        [{:put, :jobs, job.id, {job, expires_at, :queued}}, index_put_op(expires_at, job.id)]
    )
  end

  @doc """
  Get the status of a job by job_id. Returns status string or nil.
  """
  def get_status(job_id) do
    route_job(job_id, {:get_status, job_id}, fn -> get_status_local(job_id) end)
  end

  defp get_status_local(job_id) do
    case read_job_row(job_id) do
      {_job, _expires_at, status} -> to_string(status)
      nil -> nil
    end
  end

  @doc """
  Stores the terminal job result payload for later polling. The payload is
  the same shape delivered over SSE/webhook, minus the SSE-only event name.
  """
  def put_result(job_id, result, status) when status in [:completed, :failed] do
    route_job(job_id, {:put_result, job_id, result, status}, fn ->
      put_result_local(job_id, result, status)
    end)
  end

  defp put_result_local(job_id, result, status) do
    expires_at = System.system_time(:millisecond) + ttl_ms(status)
    Store.put(:results, job_id, {normalize_result(result), expires_at})
  end

  @doc """
  Returns a stored terminal result payload by job_id, or nil if the job has
  not completed/failed yet or the result has expired.
  """
  def get_result(job_id) do
    route_job(job_id, {:get_result, job_id}, fn -> get_result_local(job_id) end)
  end

  defp get_result_local(job_id) do
    now = System.system_time(:millisecond)

    case Store.get(:results, job_id) do
      {:ok, {result, expires_at}} when expires_at > now -> result
      _ -> nil
    end
  end

  @doc """
  Returns total jobs and queue depth on this node for the autoscaler headers
  sent with every dispatch. Reads running counters instead of scanning the
  jobs table: completed jobs are kept for 30 minutes, so a scan grew with
  throughput and ran on every upstream request. Expired rows count until the
  next cleanup pass (at most a minute).
  """
  def counts do
    ref = counters()
    %{total_jobs: max(:counters.get(ref, 1), 0), queue_depth: max(:counters.get(ref, 2), 0)}
  end

  # Counter 1 is every job row, counter 2 the jobs not yet completed or
  # failed. :in_flight is a status older versions wrote; it counts as queued.
  defp counters do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil -> seed_counts()
      ref -> ref
    end
  end

  @doc false
  # Rebuilds the counters from a full scan: at boot, and after the tables
  # are wiped. Public so tests can compare against a scan.
  def seed_counts do
    ref =
      case :persistent_term.get({__MODULE__, :counters}, nil) do
        nil ->
          ref = :counters.new(2, [:write_concurrency])
          :persistent_term.put({__MODULE__, :counters}, ref)
          ref

        ref ->
          ref
      end

    statuses =
      Store.fold(:jobs, [], fn {_id, {_job, _expires_at, status}}, acc -> [status | acc] end)

    :counters.put(ref, 1, length(statuses))
    :counters.put(ref, 2, Enum.count(statuses, &pending_status?/1))
    ref
  end

  defp pending_status?(status), do: status in [:queued, :in_flight]

  defp count_insert(status) do
    ref = counters()
    :counters.add(ref, 1, 1)
    if pending_status?(status), do: :counters.add(ref, 2, 1)
  end

  defp count_delete(status) do
    ref = counters()
    :counters.sub(ref, 1, 1)
    if pending_status?(status), do: :counters.sub(ref, 2, 1)
  end

  defp count_move(old, new) do
    case {pending_status?(old), pending_status?(new)} do
      {true, false} -> :counters.sub(counters(), 2, 1)
      {false, true} -> :counters.add(counters(), 2, 1)
      _ -> :ok
    end
  end

  @doc "Jobs on this node still :queued or :in_flight, webhook deliveries included."
  def pending_count do
    now = System.system_time(:millisecond)

    Store.fold(:jobs, 0, fn {_id, {_job, expires_at, status}}, n ->
      if pending_status?(status) and expires_at > now, do: n + 1, else: n
    end)
  end

  @doc """
  Get the full Job struct by job_id. Returns the Job or nil.
  """
  def get_job(job_id) do
    route_job(job_id, {:get_job, job_id}, fn -> get_job_local(job_id) end)
  end

  defp get_job_local(job_id) do
    case read_job_row(job_id) do
      {job, _expires_at, _status} -> Job.upgrade(job)
      nil -> nil
    end
  end

  @doc """
  Returns every Job currently at :queued or :in_flight status, regardless
  of expiry. Called once at boot, before the endpoint starts, to re-enqueue
  work that survived a crash or restart (see Spillway.Recovery). Jobs stay
  :queued until they finish; :in_flight is still matched so rows written by
  older versions are recovered too.
  """
  def recoverable_jobs do
    :jobs
    |> Store.fold([], fn {_id, {job, _expires_at, status}}, acc ->
      if pending_status?(status), do: [job | acc], else: acc
    end)
    |> Enum.reverse()
    |> Enum.map(&Job.upgrade/1)
  end

  @doc """
  Returns every idempotent-key ledger entry currently stored -- hash-only
  (the plaintext key is never persisted, only its hash, see hash/1). Backs
  drain mode's webhook flush (see Spillway.DrainFlush) -- an opt-in
  feature, off by default, so this is only ever called on a deployment that
  has explicitly enabled it.

  Excludes webhook-delivery jobs (see Job.webhook_delivery_job?/1) -- those
  are internal delivery bookkeeping persisted here for durability/dedup via
  check_or_insert/1, not real user-submitted work, and have no business
  appearing in a ledger meant for tenant-handoff dedup.
  """
  def list_ledger do
    :keys
    |> Store.fold([], fn {hash, {job_id, _expires_at, status}}, acc ->
      [{hash, job_id, status} | acc]
    end)
    |> Enum.reverse()
    |> Enum.reject(fn {_hash, job_id, _status} -> webhook_delivery_job_id?(job_id) end)
    |> Enum.map(fn {hash, job_id, status} ->
      %{idempotent_key_hash: hash, job_id: job_id, status: status}
    end)
  end

  @doc """
  Lists terminal drain events that have not yet been acknowledged by the
  drain webhook receiver. The sequence is local to this node and exists
  only to make batch acknowledgement precise; idempotency across nodes is
  still keyed by idempotent_key_hash.
  """
  def list_drain_events(limit \\ :all) do
    :drain_events
    |> Store.fold([], fn {job_id, {sequence, hash, status, recorded_at}}, acc ->
      [
        %{
          sequence: sequence,
          idempotent_key_hash: hash,
          job_id: job_id,
          status: status,
          recorded_at: recorded_at
        }
        | acc
      ]
    end)
    |> Enum.sort_by(& &1.sequence)
    |> take_limit(limit)
  end

  @doc """
  Deletes acknowledged drain events through the given sequence, leaving
  normal idempotency/job rows in place for hot-path duplicate checks.
  """
  def acknowledge_drain_events_through(sequence) when is_integer(sequence) do
    :drain_events
    |> Store.fold([], fn {job_id, {seq, _, _, _}}, acc ->
      if seq <= sequence, do: [{:delete, :drain_events, job_id} | acc], else: acc
    end)
    |> Store.write()
  end

  defp webhook_delivery_job_id?(job_id) do
    case read_job_row(job_id) do
      {job, _expires_at, _status} -> Job.webhook_delivery_job?(job)
      nil -> false
    end
  end

  @doc """
  Wipes all local ledger tables -- only ever called by drain mode's watchdog after
  a successful ledger-flush webhook delivery, never on a normal
  (non-drain-mode) deployment. Clears delivery modes too, alongside the
  ledger and job tables, so a handoff doesn't leave orphaned rows behind.
  """
  def clear_ledger do
    job_ids = local_job_ids()
    Store.clear([:keys, :jobs, :expiry, :results, :delivery, :drain_events, :meta])
    seed_drain_sequence()
    seed_counts()
    Enum.each(job_ids, &unregister_job_owner/1)
    :ok
  end

  @doc """
  Set delivery mode for a job. :webhook (default), :stream, :stream_fallback.
  """
  def set_delivery_mode(job_id, mode) do
    route_job(job_id, {:set_delivery_mode, job_id, mode}, fn ->
      set_delivery_mode_local(job_id, mode)
    end)
  end

  defp set_delivery_mode_local(job_id, mode) do
    Store.put(:delivery, job_id, mode)
  end

  @doc """
  Get delivery mode for a job. Returns :webhook if not set.
  """
  def get_delivery_mode(job_id) do
    route_job(job_id, {:get_delivery_mode, job_id}, fn -> get_delivery_mode_local(job_id) end)
  end

  defp get_delivery_mode_local(job_id) do
    case Store.get(:delivery, job_id) do
      {:ok, mode} -> mode
      :not_found -> :webhook
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    seed_counts()
    register_existing_job_owners()
    # Rows that expired while the node was down go now, not a minute in.
    send(self(), :cleanup)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_job_owner, job_id}, _from, state) do
    {:reply, register_job_owner_local(job_id), state}
  end

  def handle_call({:unregister_job_owner, job_id}, _from, state) do
    {:reply, unregister_job_owner_local(job_id), state}
  end

  def handle_call({:job_store, {:delete_job, job}}, _from, state),
    do: {:reply, delete_job_local(job), state}

  def handle_call({:job_store, {:discard_refused, job}}, _from, state),
    do: {:reply, discard_refused_local(job), state}

  def handle_call({:job_store, {:update_status, job_id, status}}, _from, state),
    do: {:reply, update_status_local(job_id, status), state}

  def handle_call({:job_store, {:record_retry, job}}, _from, state),
    do: {:reply, record_retry_local(job), state}

  def handle_call({:job_store, {:get_status, job_id}}, _from, state),
    do: {:reply, get_status_local(job_id), state}

  def handle_call({:job_store, {:put_result, job_id, result, status}}, _from, state),
    do: {:reply, put_result_local(job_id, result, status), state}

  def handle_call({:job_store, {:get_result, job_id}}, _from, state),
    do: {:reply, get_result_local(job_id), state}

  def handle_call({:job_store, {:get_job, job_id}}, _from, state),
    do: {:reply, get_job_local(job_id), state}

  def handle_call({:job_store, {:set_delivery_mode, job_id, mode}}, _from, state),
    do: {:reply, set_delivery_mode_local(job_id, mode), state}

  def handle_call({:job_store, {:get_delivery_mode, job_id}}, _from, state),
    do: {:reply, get_delivery_mode_local(job_id), state}

  @impl true
  def handle_info(:cleanup, state) do
    # A full batch means more are due: carry on at once, letting other
    # messages in between batches.
    if expire_due(System.system_time(:millisecond)) == @expire_batch,
      do: send(self(), :cleanup),
      else: schedule_cleanup()

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # Deletes up to limit jobs whose expiry is at or before now, with their
  # results, delivery modes and idempotency keys, reading the expiry index
  # in order. Returns how many index entries it consumed.
  def expire_due(now, limit \\ @expire_batch) do
    due =
      Store.take_from(:expiry, <<>>, limit, fn <<expires_at::unsigned-64, _::binary>> ->
        expires_at <= now
      end)

    Enum.each(due, fn {key, _} -> expire_one(key, now) end)
    length(due)
  end

  defp expire_one(<<_::unsigned-64, job_id::binary>> = key, now) do
    case read_job_row(job_id) do
      {job, expires_at, status} when expires_at <= now ->
        hashed = hash_key(job)

        Store.write(
          [
            {:delete, :jobs, job_id},
            {:delete, :results, job_id},
            {:delete, :delivery, job_id},
            {:delete, :expiry, key}
          ] ++ key_delete_ops(hashed, job_id)
        )

        count_delete(status)
        unregister_job_owner_local(job_id)

      # Already gone, or its expiry moved later (a newer index entry covers it).
      _ ->
        Store.delete(:expiry, key)
    end
  end

  defp route_job(job_id, message, local_fun) do
    local_store = Process.whereis(__MODULE__)

    case Cluster.lookup_job_store(job_id) do
      nil ->
        local_fun.()

      ^local_store ->
        local_fun.()

      owner ->
        GenServer.call(owner, {:job_store, message}, 15_000)
    end
  catch
    :exit, _reason -> local_fun.()
  end

  defp register_job_owner(job_id) do
    if Cluster.standalone?(), do: :ok, else: register_job_owner_routed(job_id)
  end

  defp register_job_owner_routed(job_id) do
    case Process.whereis(__MODULE__) do
      pid when pid == self() -> register_job_owner_local(job_id)
      _pid -> GenServer.call(__MODULE__, {:register_job_owner, job_id})
    end
  end

  defp unregister_job_owner(job_id) do
    if Cluster.standalone?(), do: :ok, else: unregister_job_owner_routed(job_id)
  end

  defp unregister_job_owner_routed(job_id) do
    case Process.whereis(__MODULE__) do
      pid when pid == self() -> unregister_job_owner_local(job_id)
      _pid -> GenServer.call(__MODULE__, {:unregister_job_owner, job_id})
    end
  end

  defp register_job_owner_local(job_id) do
    # Job ownership only matters for routing between nodes. Registering every
    # job with Syn went through one process per job, so standalone nodes skip
    # it; lookups then miss and fall back to the local store.
    if Cluster.standalone?(), do: :ok, else: register_job_owner_syn(job_id)
  end

  defp register_job_owner_syn(job_id) do
    case :syn.register(Cluster.job_store_scope(), job_id, self()) do
      :ok -> :ok
      {:error, :taken} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp unregister_job_owner_local(job_id) do
    case Cluster.lookup_job_store(job_id) do
      pid when pid == self() -> :syn.unregister(Cluster.job_store_scope(), job_id)
      _ -> :ok
    end
  end

  # Standalone nodes register nothing (see register_job_owner_local/1), so
  # they skip the scan of every job id too.
  defp register_existing_job_owners do
    unless Cluster.standalone?(),
      do: Enum.each(local_job_ids(), &register_job_owner_syn/1)
  end

  defp local_job_ids do
    :jobs |> Store.fold([], fn {id, _}, acc -> [id | acc] end) |> Enum.reverse()
  end

  # ---- Private ----

  # Only drain mode reads drain events. Returns the writes that record one,
  # for update_status to apply in its batch.
  defp drain_event_ops(%Job{} = job, hashed, status) when status in [:completed, :failed] do
    if Job.webhook_delivery_job?(job) or not drain_events_enabled?() or
         Store.get(:drain_events, job.id) != :not_found do
      []
    else
      sequence = :atomics.add_get(drain_sequence(), 1, 1)
      recorded_at = System.system_time(:millisecond)

      [
        {:put, :drain_events, job.id, {sequence, hashed, status, recorded_at}},
        {:put, :meta, "drain_sequence", sequence}
      ]
    end
  end

  defp drain_event_ops(_job, _hashed, _status), do: []

  defp drain_events_enabled? do
    case System.get_env("SPILLWAY_DRAIN_ENABLED") do
      nil -> false
      val -> String.downcase(val) in ["1", "true", "yes"]
    end
  end

  # The last drain sequence handed out. Held in :atomics so concurrent status
  # updates never reuse one; each recorded event also stores it in :meta.
  defp drain_sequence do
    case :persistent_term.get({__MODULE__, :drain_sequence}, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put({__MODULE__, :drain_sequence}, ref)
        ref

      ref ->
        ref
    end
  end

  defp seed_drain_sequence do
    last =
      case Store.get(:meta, "drain_sequence") do
        {:ok, n} when is_integer(n) -> n
        :not_found -> 0
      end

    :atomics.put(drain_sequence(), 1, last)
  end

  defp take_limit(entries, :all), do: entries

  defp take_limit(entries, limit) when is_integer(limit) and limit > 0 do
    Enum.take(entries, limit)
  end

  defp take_limit(entries, _limit), do: entries

  defp normalize_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), value} end)
  end

  # Scoped per user_id, matching Aquifer's hashKey(job.UserID + ":" + job.IdempotentKey) exactly --
  # without this, two different users submitting the same idempotent_key would collide with each
  # other (User B's request silently treated as a duplicate of User A's, never actually running).
  # This was a real porting gap, not a deliberate difference from Aquifer's documented contract
  # ("duplicate idempotent_key per user_id returns the existing job", README.md) -- found and fixed
  # while reviewing drain mode's ledger-hash documentation.
  #
  # Shared-scope jobs (see Job.shared_idempotency_enabled?/0) dedup on the key
  # alone, matching Aquifer's dedupHash. Map.get, not job.idempotency_scope:
  # jobs persisted before this field existed are stored without it.
  defp hash_key(%Job{} = job) do
    case Map.get(job, :idempotency_scope) do
      "shared" -> hash("shared" <> <<0>> <> job.idempotent_key)
      _ -> hash(job.user_id <> ":" <> job.idempotent_key)
    end
  end

  defp hash(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp ttl_ms(:completed), do: 30 * 60 * 1_000
  defp ttl_ms(:failed), do: 2 * 60 * 60 * 1_000
  defp ttl_ms(_), do: Application.get_env(:spillway, :idempotent_ttl, 86_400) * 1_000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
