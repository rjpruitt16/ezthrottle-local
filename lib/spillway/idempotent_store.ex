# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.IdempotentStore do
  @moduledoc """
  Mnesia-backed store for idempotent keys and full job structs with TTL.

  Tables are disc_copies for crash durability:
  - :idempotent_keys  — keyed by hashed idempotent_key, prevents duplicate execution
  - :jobs             — keyed by job_id, stores the full Job struct for status lookup
  - :job_results      — keyed by job_id, stores terminal response payloads for polling
  - :drain_events     — keyed by job_id, stores terminal ledger events until acknowledged

  Raw client keys are never stored — they are hashed before insertion.
  TTL defaults to 24 hours and is configurable via :idempotent_ttl.

  check_or_insert/1 reads-then-writes inside a single :mnesia.transaction,
  which is what makes the duplicate check atomic. The previous ETS-backed
  version did :ets.lookup followed by a separate :ets.insert — two
  non-atomic steps — so two concurrent requests with the same idempotent
  key could both observe an empty lookup and both proceed to insert,
  silently defeating the one guarantee this function exists to provide.
  """

  use GenServer

  require Logger

  alias Spillway.Job
  alias Spillway.Cluster

  @keys_table :idempotent_keys
  @jobs_table :jobs
  @results_table :job_results
  @delivery_table :job_delivery_modes
  @drain_events_table :drain_events
  @drain_sequence_table :drain_sequence
  # Expired jobs are found through @expiry_table, an index ordered by expiry,
  # and deleted a batch at a time. The pass used to select every expired row
  # of every table inside one transaction: on a busy node that was hundreds
  # of thousands of locks, it fell behind under load and stopped freeing
  # memory at all (soak run 3).
  @expiry_table :job_expiry
  @cleanup_interval_ms 10_000
  @expire_batch 2_000

  # SPILLWAY_STORAGE=rocksdb keeps these tables in RocksDB (mnesia_rocksdb)
  # instead of RAM, so memory no longer grows with how many jobs are
  # retained, and a restart doesn't reload them all into RAM.
  @disk_tables [
    :idempotent_keys,
    :jobs,
    :job_results,
    :job_delivery_modes,
    :drain_events,
    :job_expiry
  ]

  # Finished jobs are kept for their retention (30 minutes completed, 2
  # hours failed), and these tables live in RAM, so at a high enough job
  # rate retention alone outgrows the machine. When the VM's memory passes
  # @evict_at_pct of SPILLWAY_MEMORY_LIMIT_MB, each check evicts the oldest
  # @evict_fraction of finished jobs, early. Queued and in-flight jobs are
  # never evicted. The VM's own count is used here, not resident memory: it
  # drops as soon as rows are deleted, so eviction stops once it has freed
  # enough, while resident memory can stay high after the allocator frees.
  # Resident memory runs up to ~1.4x the VM count, so 70% keeps it under
  # the limit admission enforces.
  @memory_check_interval_ms 5_000
  @evict_at_pct 70
  # Resident memory past this share of the limit also triggers eviction.
  # Admission refuses at 100% of it, and eviction used to look only at the
  # VM's count, which can sit under 70% while resident memory (about 1.5x it
  # in soak run 3) is over the limit: admission then refused every job and
  # eviction never ran.
  @evict_rss_pct 90
  @evict_fraction 0.1
  @evict_chunk 500

  # SPILLWAY_MNESIA_FLUSH_INTERVAL_MS controls the durability/throughput
  # trade-off directly: 0 means flush every single write synchronously
  # inline (zero data loss ever, but a real disk-flush cost on every
  # request — this is what made request latency and the safe ingest
  # ceiling worse than Aquifer's WAL-based SQLite, which batches its own
  # fsyncs under the hood). A positive value batches writes and flushes on
  # a timer instead, bounding the loss window to at most this many ms of
  # writes on a true crash — the same trade-off SQLite's own
  # synchronous=NORMAL already makes, and Postgres's synchronous_commit=off
  # makes explicitly. Defaults to 100ms: a small, usually-acceptable window
  # in exchange for not paying a disk flush on every request.
  @default_flush_interval_ms 100

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Ensures the Mnesia schema and tables exist on disk, creating them on
  first boot. Must be called before any other function here, and before
  any process tries to use the tables. Idempotent — safe to call on every
  boot, including ones where the schema already exists from a prior run.
  """
  def ensure_schema! do
    node_list = [node()]

    case :mnesia.create_schema(node_list) do
      :ok -> Logger.info("[Mnesia] created new on-disk schema")
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, reason} -> Logger.warning("[Mnesia] create_schema: #{inspect(reason)}")
    end

    :ok = :mnesia.start()
    register_storage_backend()

    ensure_table(@keys_table, [:hashed_key, :job_id, :expires_at, :status], node_list)
    ensure_table(@jobs_table, [:job_id, :job, :expires_at, :status], node_list)
    ensure_table(@results_table, [:job_id, :result, :expires_at], node_list)
    ensure_table(@delivery_table, [:job_id, :mode], node_list)

    ensure_table(
      @drain_events_table,
      [:job_id, :sequence, :idempotent_key_hash, :status, :recorded_at],
      node_list
    )

    ensure_table(@drain_sequence_table, [:key, :value], node_list)
    ensure_table(@expiry_table, [:key, :value], node_list, :ordered_set)

    :mnesia.wait_for_tables(
      [
        @keys_table,
        @jobs_table,
        @results_table,
        @delivery_table,
        @drain_events_table,
        @drain_sequence_table,
        @expiry_table
      ],
      30_000
    )

    migrate_renamed_jobs()
    backfill_expiry_index()
  end

  @doc "\"rocksdb\" when SPILLWAY_STORAGE=rocksdb, otherwise \"ram\"."
  def storage do
    case System.get_env("SPILLWAY_STORAGE", "ram") |> String.trim() |> String.downcase() do
      "rocksdb" -> "rocksdb"
      _ -> "ram"
    end
  end

  defp rocksdb?, do: storage() == "rocksdb"

  defp register_storage_backend do
    if rocksdb?() do
      case :mnesia_rocksdb.register() do
        {:ok, _alias} -> :ok
        {:error, {:already_exists, _}} -> :ok
        other -> Logger.info("[Mnesia] mnesia_rocksdb.register: #{inspect(other)}")
      end
    end
  end

  # A store created before the expiry index existed gets one pass that
  # indexes every job.
  defp backfill_expiry_index do
    if :mnesia.dirty_first(@expiry_table) == :"$end_of_table" do
      rows =
        :mnesia.dirty_select(@jobs_table, [
          {{@jobs_table, :"$1", :_, :"$2", :_}, [], [{{:"$2", :"$1"}}]}
        ])

      Enum.each(rows, fn {expires_at, job_id} -> index_put(expires_at, job_id) end)
      if rows != [], do: Logger.info("[Mnesia] indexed the expiry of #{length(rows)} jobs")
    end

    :ok
  end

  defp index_put(expires_at, job_id),
    do: :mnesia.dirty_write({@expiry_table, {expires_at, job_id}, nil})

  defp index_delete(expires_at, job_id),
    do: :mnesia.dirty_delete({@expiry_table, {expires_at, job_id}})

  # Spillway was EzthrottleLocal, and Mnesia stores each job as a struct
  # tagged with its module name. A job saved before the rename would load as
  # a map tagged with a module that no longer exists and match nothing, so
  # retag those once at boot. A no-op on a node that never ran the old name.
  @legacy_job_struct Module.concat(["Ezthrottle" <> "Local", "Job"])

  @doc false
  def migrate_renamed_jobs do
    legacy =
      :mnesia.dirty_select(@jobs_table, [
        {{@jobs_table, :_, %{__struct__: @legacy_job_struct}, :_, :_}, [], [:"$_"]}
      ])

    for {table, job_id, job, expires_at, status} <- legacy do
      :mnesia.dirty_write({table, job_id, retag_job(job), expires_at, status})
    end

    if legacy != [] do
      Logger.info("[Mnesia] retagged #{length(legacy)} jobs saved before the rename to Spillway")
    end

    :ok
  end

  @doc false
  def retag_job(%{__struct__: @legacy_job_struct} = job),
    do: struct(Spillway.Job, Map.delete(job, :__struct__))

  def retag_job(job), do: job

  defp ensure_table(name, attrs, node_list, type \\ :set) do
    copies = if rocksdb?() and name in @disk_tables, do: :rocksdb_copies, else: :disc_copies

    # RocksDB tables use direct access (config :mnesia_rocksdb,
    # :default_access_type).
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, type}, {copies, node_list}]) do
      {:atomic, :ok} ->
        Logger.info("[Mnesia] created table #{name} (#{copies})")

      {:aborted, {:already_exists, ^name}} ->
        convert_table(name, copies)

      {:aborted, reason} ->
        Logger.error("[Mnesia] failed to create table #{name}: #{inspect(reason)}")
    end
  end

  # A table created under the other storage setting is converted in place.
  defp convert_table(name, copies) do
    if storage_type(name) != copies do
      case :mnesia.change_table_copy_type(name, node(), copies) do
        {:atomic, :ok} ->
          Logger.info("[Mnesia] moved table #{name} to #{copies}")

        {:aborted, reason} ->
          Logger.error("[Mnesia] could not move table #{name} to #{copies}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc false
  # Plugin storage reports as {:ext, alias, module}.
  def storage_type(table) do
    case :mnesia.table_info(table, :storage_type) do
      {:ext, alias, _module} -> alias
      type -> type
    end
  end

  @doc "The id of the job already holding this job's idempotency key, or nil."
  def existing_job_id(%Job{} = job) do
    hashed = hash_key(job)

    case :mnesia.dirty_read(@keys_table, hashed) do
      [{@keys_table, ^hashed, job_id, _expires_at, _status}] -> job_id
      [] -> nil
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
      case gate_lock(hashed, job.id) do
        :locked ->
          # Holding the key's lock makes this the only insert for the key
          # until it's released, so the check and the writes run without a
          # transaction: no trip through Mnesia's lock manager per
          # submission. Dirty writes are still logged.
          try do
            case :mnesia.dirty_read(@keys_table, hashed) do
              [{@keys_table, ^hashed, existing_id, _expires_at, _status}] ->
                {:duplicate, existing_id}

              [] ->
                :mnesia.dirty_write({@keys_table, hashed, job.id, expires_at, :queued})
                :mnesia.dirty_write({@jobs_table, job.id, job, expires_at, :queued})
                index_put(expires_at, job.id)
                :ok
            end
          after
            gate_unlock(hashed)
          end

        :no_gate ->
          check_or_insert_transaction(hashed, job, expires_at)
      end

    finish_check_or_insert(job, result)
  end

  # The key gate: a lock per idempotency key, held only while one insert
  # checks the keys table and writes. :ets.insert_new is atomic, so of any
  # concurrent inserts for one key exactly one holds it; the others wait,
  # then find its row and report a duplicate. It used to mirror every key
  # in the keys table, which kept all of them in RAM whatever the storage.
  # Without the table (it's owned by this GenServer), fall back to the
  # transaction.
  @key_gate :idempotent_key_gate

  # The lock records its holder, so a lock left by a process that died
  # holding it (killed between lock and unlock) is taken over instead of
  # blocking that key forever.
  defp gate_lock(hashed, job_id) do
    if :ets.insert_new(@key_gate, {hashed, self()}) do
      :locked
    else
      case :ets.lookup(@key_gate, hashed) do
        [{^hashed, holder} = entry] when is_pid(holder) ->
          unless Process.alive?(holder), do: :ets.delete_object(@key_gate, entry)

        _ ->
          :ok
      end

      :erlang.yield()
      gate_lock(hashed, job_id)
    end
  rescue
    ArgumentError -> :no_gate
  end

  defp gate_unlock(hashed) do
    :ets.delete_object(@key_gate, {hashed, self()})
  rescue
    ArgumentError -> :ok
  end

  defp create_key_gate do
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

  defp check_or_insert_transaction(hashed, job, expires_at) do
    {:atomic, result} =
      :mnesia.sync_transaction(fn ->
        case :mnesia.read(@keys_table, hashed) do
          [{@keys_table, ^hashed, existing_id, _expires_at, _status}] ->
            {:duplicate, existing_id}

          [] ->
            :mnesia.write({@keys_table, hashed, job.id, expires_at, :queued})
            :mnesia.write({@jobs_table, job.id, job, expires_at, :queued})
            :mnesia.write({@expiry_table, {expires_at, job.id}, nil})
            :ok
        end
      end)

    result
  end

  defp finish_check_or_insert(job, result) do
    # disc_copies tables live in RAM with the disk copy kept current via a
    # transaction log that Mnesia only flushes at its own periodic
    # threshold (by default: every 100 writes or every 3 minutes,
    # whichever comes first) — a plain (or even sync_) transaction commits
    # in memory well before that log entry is actually on disk. Without
    # ever forcing a flush, a killed process loses every write since the
    # last periodic dump, which defeats the entire point of durability
    # here. flush_interval_ms/0 == 0 flushes inline on every write (zero
    # loss, real per-request cost); a positive value leaves it to the
    # periodic ticker in handle_info(:flush_log, ...) instead, bounding
    # loss to that interval without paying the cost per request.
    if flush_interval_ms() == 0, do: :mnesia.dump_log()

    case result do
      :ok ->
        count_insert(:queued)
        register_job_owner(job.id)

      {:duplicate, existing_id} ->
        register_job_owner(existing_id)
    end

    result
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

  defp discard_refused_local(%Job{} = job) do
    hashed = hash_key(job)
    job_id = job.id

    old_status =
      case :mnesia.dirty_read(@jobs_table, job_id) do
        [{@jobs_table, ^job_id, _, expires_at, status}] ->
          index_delete(expires_at, job_id)
          status

        [] ->
          nil
      end

    :mnesia.dirty_delete({@jobs_table, job_id})
    :mnesia.dirty_delete({@results_table, job_id})
    :mnesia.dirty_delete({@delivery_table, job_id})

    case :mnesia.dirty_read(@keys_table, hashed) do
      [{@keys_table, ^hashed, ^job_id, _, _}] -> :mnesia.dirty_delete({@keys_table, hashed})
      _ -> :ok
    end

    if old_status, do: count_delete(old_status)
    unregister_job_owner(job_id)
    :ok
  end

  defp delete_job_local(%Job{} = job) do
    hashed = hash_key(job)

    {:atomic, old_status} =
      :mnesia.sync_transaction(fn ->
        old_status =
          case :mnesia.read(@jobs_table, job.id) do
            [{@jobs_table, _, _, expires_at, status}] ->
              :mnesia.delete({@expiry_table, {expires_at, job.id}})
              status

            [] ->
              nil
          end

        :mnesia.delete({@jobs_table, job.id})
        :mnesia.delete({@results_table, job.id})
        :mnesia.delete({@delivery_table, job.id})
        :mnesia.delete({@keys_table, hashed})
        old_status
      end)

    if old_status, do: count_delete(old_status)

    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    unregister_job_owner(job.id)

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
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, old_expires, old_status}] ->
        new_expires = System.system_time(:millisecond) + ttl_ms(status)
        :mnesia.dirty_write({@jobs_table, job_id, job, new_expires, status})
        index_put(new_expires, job_id)
        index_delete(old_expires, job_id)
        count_move(old_status, status)

        hashed = hash_key(job)

        case :mnesia.dirty_read(@keys_table, hashed) do
          [{@keys_table, ^hashed, ^job_id, _key_expires, _}] ->
            :mnesia.dirty_write({@keys_table, hashed, job_id, new_expires, status})

          _ ->
            :ok
        end

        maybe_record_drain_event(job, hashed, status)

        :ok

      [] ->
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

    case :mnesia.dirty_read(@jobs_table, job.id) do
      [{@jobs_table, _, _, old_expires, _}] -> index_delete(old_expires, job.id)
      [] -> :ok
    end

    :mnesia.dirty_write({@jobs_table, job.id, job, expires_at, :queued})
    index_put(expires_at, job.id)
    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    :ok
  end

  @doc """
  Get the status of a job by job_id. Returns status string or nil.
  """
  def get_status(job_id) do
    route_job(job_id, {:get_status, job_id}, fn -> get_status_local(job_id) end)
  end

  defp get_status_local(job_id) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, _job, _expires_at, status}] -> to_string(status)
      [] -> nil
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
    :mnesia.dirty_write({@results_table, job_id, normalize_result(result), expires_at})
    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    :ok
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

    case :mnesia.dirty_read(@results_table, job_id) do
      [{@results_table, ^job_id, result, expires_at}] when expires_at > now -> result
      [{@results_table, ^job_id, _result, _expires_at}] -> nil
      [] -> nil
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
      :mnesia.dirty_select(@jobs_table, [{{@jobs_table, :_, :_, :_, :"$1"}, [], [:"$1"]}])

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

    :mnesia.dirty_select(@jobs_table, [
      {{@jobs_table, :_, :_, :"$1", :queued}, [{:>, :"$1", now}], [true]},
      {{@jobs_table, :_, :_, :"$1", :in_flight}, [{:>, :"$1", now}], [true]}
    ])
    |> length()
  end

  @doc """
  Get the full Job struct by job_id. Returns the Job or nil.
  """
  def get_job(job_id) do
    route_job(job_id, {:get_job, job_id}, fn -> get_job_local(job_id) end)
  end

  defp get_job_local(job_id) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, _expires_at, _status}] -> Job.upgrade(job)
      [] -> nil
    end
  end

  @doc """
  Returns every Job currently at :queued or :in_flight status, regardless
  of expiry. Called once at boot, before the endpoint starts, to re-enqueue
  work that survived a crash or restart (see Spillway.Recovery). Jobs stay
  :queued until they finish; :in_flight is still matched so rows written by
  older versions are recovered too.

  A dirty scan: nothing else writes during boot, so a transaction's table
  lock would protect nothing.
  """
  def recoverable_jobs do
    jobs =
      :mnesia.dirty_select(@jobs_table, [
        {{@jobs_table, :_, :"$1", :_, :queued}, [], [:"$1"]},
        {{@jobs_table, :_, :"$1", :_, :in_flight}, [], [:"$1"]}
      ])

    Enum.map(jobs, &Job.upgrade/1)
  end

  @doc """
  Returns every idempotent-key ledger entry currently stored -- hash-only,
  matching what this table has always stored (the plaintext key is never
  persisted, only its hash, see hash/1). Backs drain mode's webhook flush
  (see Spillway.DrainFlush) -- an opt-in feature, off by default, so
  this is only ever called on a deployment that has explicitly enabled it.

  Excludes webhook-delivery jobs (see Job.webhook_delivery_job?/1) -- those
  are internal delivery bookkeeping persisted here for durability/dedup via
  check_or_insert/1, not real user-submitted work, and have no business
  appearing in a ledger meant for tenant-handoff dedup.
  """
  def list_ledger do
    {:atomic, entries} =
      :mnesia.transaction(fn ->
        :mnesia.select(@keys_table, [
          {{@keys_table, :"$1", :"$2", :_, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])
      end)

    entries
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
    {:atomic, entries} =
      :mnesia.transaction(fn ->
        :mnesia.select(@drain_events_table, [
          {{@drain_events_table, :"$1", :"$2", :"$3", :"$4", :"$5"}, [],
           [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]}
        ])
      end)

    entries
    |> Enum.map(fn {job_id, sequence, hash, status, recorded_at} ->
      %{
        sequence: sequence,
        idempotent_key_hash: hash,
        job_id: job_id,
        status: status,
        recorded_at: recorded_at
      }
    end)
    |> Enum.sort_by(& &1.sequence)
    |> take_limit(limit)
  end

  @doc """
  Deletes acknowledged drain events through the given sequence, leaving
  normal idempotency/job rows in place for hot-path duplicate checks.
  """
  def acknowledge_drain_events_through(sequence) when is_integer(sequence) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        :mnesia.select(@drain_events_table, [
          {{@drain_events_table, :_, :"$1", :_, :_, :_}, [{:"=<", :"$1", sequence}], [:"$_"]}
        ])
      end)

    :mnesia.transaction(fn ->
      Enum.each(rows, fn row -> :mnesia.delete_object(row) end)
    end)

    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    :ok
  end

  defp webhook_delivery_job_id?(job_id) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, _expires_at, _status}] -> Job.webhook_delivery_job?(job)
      [] -> false
    end
  end

  @doc """
  Wipes all local ledger tables -- only ever called by drain mode's watchdog after
  a successful ledger-flush webhook delivery, never on a normal
  (non-drain-mode) deployment. Clears job_delivery_modes too, alongside the
  ledger and job tables, so a handoff doesn't leave orphaned rows behind.
  """
  def clear_ledger do
    job_ids = local_job_ids()

    Enum.each(
      [
        @keys_table,
        @jobs_table,
        @expiry_table,
        @results_table,
        @delivery_table,
        @drain_events_table,
        @drain_sequence_table
      ],
      &empty_table/1
    )

    seed_counts()
    Enum.each(job_ids, &unregister_job_owner/1)
    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    :ok
  end

  # :mnesia.clear_table on a RocksDB table drops and recreates it under any
  # process still reading or writing it directly, and the VM segfaulted in
  # RocksDB's NIF when one was (found in the test suite). Delete the rows
  # instead; RAM tables still use clear_table.
  defp empty_table(table) do
    if storage_type(table) == :rocksdb_copies do
      table |> :mnesia.dirty_all_keys() |> Enum.each(&:mnesia.dirty_delete(table, &1))
    else
      :mnesia.clear_table(table)
    end
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
    :mnesia.dirty_write({@delivery_table, job_id, mode})
    :ok
  end

  @doc """
  Get delivery mode for a job. Returns :webhook if not set.
  """
  def get_delivery_mode(job_id) do
    route_job(job_id, {:get_delivery_mode, job_id}, fn -> get_delivery_mode_local(job_id) end)
  end

  defp get_delivery_mode_local(job_id) do
    case :mnesia.dirty_read(@delivery_table, job_id) do
      [{@delivery_table, ^job_id, mode}] -> mode
      [] -> :webhook
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    create_key_gate()
    seed_counts()
    register_existing_job_owners()
    # Rows that expired while the node was down go now, not a minute in.
    send(self(), :cleanup)
    schedule_memory_check()
    schedule_flush()
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

  def handle_info(:check_memory, state) do
    enforce_memory_budget()
    schedule_memory_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_log, state) do
    interval = flush_interval_ms()

    if interval > 0 do
      :mnesia.dump_log()
      Process.send_after(self(), :flush_log, interval)
    end

    {:noreply, state}
  end

  defp schedule_flush do
    interval = flush_interval_ms()
    if interval > 0, do: Process.send_after(self(), :flush_log, interval)
  end

  defp flush_interval_ms do
    case System.get_env("SPILLWAY_MNESIA_FLUSH_INTERVAL_MS") do
      nil ->
        @default_flush_interval_ms

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> @default_flush_interval_ms
        end
    end
  end

  @doc false
  # Deletes up to limit jobs whose expiry is at or before now, with their
  # results, delivery modes and idempotency keys, reading the expiry index
  # in order. Returns how many index entries it consumed.
  def expire_due(now, limit \\ @expire_batch) do
    due = due_keys(:mnesia.dirty_first(@expiry_table), now, limit, [])
    Enum.each(due, &expire_one(&1, now))
    length(due)
  end

  defp due_keys(:"$end_of_table", _now, _limit, acc), do: Enum.reverse(acc)
  defp due_keys(_key, _now, 0, acc), do: Enum.reverse(acc)

  defp due_keys({expires_at, _job_id} = key, now, limit, acc) when expires_at <= now,
    do: due_keys(:mnesia.dirty_next(@expiry_table, key), now, limit - 1, [key | acc])

  defp due_keys(_key, _now, _limit, acc), do: Enum.reverse(acc)

  defp expire_one({_expires_at, job_id} = key, now) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, expires_at, status}] when expires_at <= now ->
        hashed = hash_key(job)
        :mnesia.dirty_delete({@jobs_table, job_id})
        :mnesia.dirty_delete({@results_table, job_id})
        :mnesia.dirty_delete({@delivery_table, job_id})

        case :mnesia.dirty_read(@keys_table, hashed) do
          [{@keys_table, ^hashed, ^job_id, _, _}] -> :mnesia.dirty_delete({@keys_table, hashed})
          _ -> :ok
        end

        count_delete(status)
        unregister_job_owner_local(job_id)

      # Already gone, or its expiry moved later (a newer index entry covers it).
      _ ->
        :ok
    end

    :mnesia.dirty_delete({@expiry_table, key})
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
    :mnesia.dirty_select(@jobs_table, [
      {{@jobs_table, :"$1", :_, :_, :_}, [], [:"$1"]}
    ])
  end

  # ---- Private ----

  # Only drain mode reads drain events. With it off, recording one was a
  # sync_transaction per finished job, into a table nothing acknowledges.
  defp maybe_record_drain_event(%Job{} = job, hashed, status)
       when status in [:completed, :failed] do
    unless Job.webhook_delivery_job?(job) or not drain_events_enabled?() do
      job_id = job.id
      recorded_at = System.system_time(:millisecond)

      :mnesia.sync_transaction(fn ->
        case :mnesia.read(@drain_events_table, job_id) do
          [{@drain_events_table, ^job_id, _sequence, _hash, _status, _recorded_at}] ->
            :ok

          [] ->
            sequence = next_drain_sequence()
            :mnesia.write({@drain_events_table, job_id, sequence, hashed, status, recorded_at})
            :ok
        end
      end)

      if flush_interval_ms() == 0, do: :mnesia.dump_log()
    end
  end

  defp maybe_record_drain_event(_job, _hashed, _status), do: :ok

  defp drain_events_enabled? do
    case System.get_env("SPILLWAY_DRAIN_ENABLED") do
      nil -> false
      val -> String.downcase(val) in ["1", "true", "yes"]
    end
  end

  defp next_drain_sequence do
    next =
      case :mnesia.read(@drain_sequence_table, :sequence) do
        [{@drain_sequence_table, :sequence, current}] when is_integer(current) -> current + 1
        [] -> 1
      end

    :mnesia.write({@drain_sequence_table, :sequence, next})
    next
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

  defp schedule_memory_check do
    Process.send_after(self(), :check_memory, @memory_check_interval_ms)
  end

  @doc false
  # Evicts the oldest finished jobs when the VM's memory is past
  # @evict_at_pct of SPILLWAY_MEMORY_LIMIT_MB. Off when the limit is unset.
  # Returns how many jobs it evicted.
  def enforce_memory_budget do
    limit = Spillway.Admission.memory_limit_mb()

    over? =
      Spillway.MemoryUsage.vm_mb() * 100 > limit * @evict_at_pct or
        Spillway.MemoryUsage.mb() * 100 > limit * @evict_rss_pct

    # With RocksDB storage finished jobs aren't held in RAM, so evicting
    # them early frees nothing.
    if limit > 0 and not rocksdb?() and over? do
      finished = finished_job_count()
      n = max(1, ceil(finished * @evict_fraction))
      evicted = evict_finished(n)

      if evicted > 0 do
        Logger.warning(
          "[IdempotentStore] memory past #{@evict_at_pct}% of SPILLWAY_MEMORY_LIMIT_MB: " <>
            "evicted the #{evicted} oldest of #{finished} finished jobs before their retention ended"
        )
      end

      evicted
    else
      0
    end
  end

  @doc false
  # Deletes the n finished (completed or failed) jobs whose retention ends
  # soonest, with their results, delivery modes and idempotency keys.
  def evict_finished(n) when n > 0 do
    @jobs_table
    |> :mnesia.dirty_select([
      {{@jobs_table, :"$1", :_, :"$2", :"$3"},
       [{:orelse, {:==, :"$3", :completed}, {:==, :"$3", :failed}}], [{{:"$2", :"$1"}}]}
    ])
    |> Enum.sort()
    |> Enum.take(n)
    |> Enum.chunk_every(@evict_chunk)
    |> Enum.reduce(0, fn chunk, total -> total + evict_chunk(chunk) end)
  end

  def evict_finished(_n), do: 0

  defp evict_chunk(chunk) do
    {:atomic, evicted} =
      :mnesia.transaction(fn ->
        Enum.flat_map(chunk, fn {_expires_at, job_id} ->
          case :mnesia.read(@jobs_table, job_id) do
            [{@jobs_table, ^job_id, job, expires_at, status}]
            when status in [:completed, :failed] ->
              hashed = hash_key(job)
              :mnesia.delete({@expiry_table, {expires_at, job_id}})
              :mnesia.delete({@jobs_table, job_id})
              :mnesia.delete({@results_table, job_id})
              :mnesia.delete({@delivery_table, job_id})

              # A newer job may own the key by now; only drop it if it's ours.
              case :mnesia.read(@keys_table, hashed) do
                [{@keys_table, ^hashed, ^job_id, _, _}] -> :mnesia.delete({@keys_table, hashed})
                _ -> :ok
              end

              [{job_id, hashed, status}]

            _ ->
              []
          end
        end)
      end)

    Enum.each(evicted, fn {job_id, _hashed, status} ->
      count_delete(status)
      unregister_job_owner_local(job_id)
    end)

    length(evicted)
  end

  defp finished_job_count do
    :mnesia.dirty_select(@jobs_table, [
      {{@jobs_table, :_, :_, :_, :"$1"},
       [{:orelse, {:==, :"$1", :completed}, {:==, :"$1", :failed}}], [true]}
    ])
    |> length()
  end
end
