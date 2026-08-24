defmodule EzthrottleLocal.IdempotentStore do
  @moduledoc """
  Mnesia-backed store for idempotent keys and full job structs with TTL.

  Two tables, both disc_copies for crash durability:
  - :idempotent_keys  — keyed by hashed idempotent_key, prevents duplicate execution
  - :jobs             — keyed by job_id, stores the full Job struct for status lookup

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

  alias EzthrottleLocal.Job

  @keys_table :idempotent_keys
  @jobs_table :jobs
  @delivery_table :job_delivery_modes
  @cleanup_interval_ms 60_000

  # EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS controls the durability/throughput
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

    ensure_table(@keys_table, [:hashed_key, :job_id, :expires_at, :status], node_list)
    ensure_table(@jobs_table, [:job_id, :job, :expires_at, :status], node_list)
    ensure_table(@delivery_table, [:job_id, :mode], node_list)

    :mnesia.wait_for_tables([@keys_table, @jobs_table, @delivery_table], 30_000)
  end

  defp ensure_table(name, attrs, node_list) do
    case :mnesia.create_table(name, attributes: attrs, disc_copies: node_list, type: :set) do
      {:atomic, :ok} ->
        Logger.info("[Mnesia] created table #{name}")

      {:aborted, {:already_exists, ^name}} ->
        :ok

      {:aborted, reason} ->
        Logger.error("[Mnesia] failed to create table #{name}: #{inspect(reason)}")
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

    {:atomic, result} =
      :mnesia.sync_transaction(fn ->
        case :mnesia.read(@keys_table, hashed) do
          [{@keys_table, ^hashed, existing_id, _expires_at, _status}] ->
            {:duplicate, existing_id}

          [] ->
            :mnesia.write({@keys_table, hashed, job.id, expires_at, :queued})
            :mnesia.write({@jobs_table, job.id, job, expires_at, :queued})
            :ok
        end
      end)

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
    hashed = hash_key(job)

    :mnesia.sync_transaction(fn ->
      :mnesia.delete({@jobs_table, job.id})
      :mnesia.delete({@keys_table, hashed})
    end)

    if flush_interval_ms() == 0, do: :mnesia.dump_log()

    :ok
  end

  @doc """
  Update the status of a job by job_id in both tables.
  """
  def update_status(job_id, status) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, _expires_at, _old_status}] ->
        new_expires = System.system_time(:millisecond) + ttl_ms(status)
        :mnesia.dirty_write({@jobs_table, job_id, job, new_expires, status})

        hashed = hash_key(job)

        case :mnesia.dirty_read(@keys_table, hashed) do
          [{@keys_table, ^hashed, ^job_id, _key_expires, _}] ->
            :mnesia.dirty_write({@keys_table, hashed, job_id, new_expires, status})

          _ ->
            :ok
        end

        :ok

      [] ->
        :error
    end
  end

  @doc """
  Get the status of a job by job_id. Returns status string or nil.
  """
  def get_status(job_id) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, _job, _expires_at, status}] -> to_string(status)
      [] -> nil
    end
  end

  @doc """
  Returns total jobs and queue depth from Mnesia for autoscaler headers.
  """
  def counts do
    now = System.system_time(:millisecond)

    total =
      :mnesia.dirty_select(@jobs_table, [
        {{@jobs_table, :_, :_, :"$1", :_}, [{:>, :"$1", now}], [true]}
      ])
      |> length()

    queued =
      :mnesia.dirty_select(@jobs_table, [
        {{@jobs_table, :_, :_, :"$1", :queued}, [{:>, :"$1", now}], [true]}
      ])
      |> length()

    %{total_jobs: total, queue_depth: queued}
  end

  @doc """
  Get the full Job struct by job_id. Returns the Job or nil.
  """
  def get_job(job_id) do
    case :mnesia.dirty_read(@jobs_table, job_id) do
      [{@jobs_table, ^job_id, job, _expires_at, _status}] -> job
      [] -> nil
    end
  end

  @doc """
  Returns every Job currently at :queued or :in_flight status, regardless
  of expiry. Called once at boot to re-enqueue work that survived a crash
  or restart — :in_flight is included because a job that was mid-dispatch
  when the node died has no way to resume on its own; treating it like a
  fresh :queued job is the same "safety net" Aquifer applies to stale
  in-flight jobs.
  """
  def recoverable_jobs do
    {:atomic, jobs} =
      :mnesia.transaction(fn ->
        :mnesia.select(@jobs_table, [
          {{@jobs_table, :_, :"$1", :_, :queued}, [], [:"$1"]},
          {{@jobs_table, :_, :"$1", :_, :in_flight}, [], [:"$1"]}
        ])
      end)

    jobs
  end

  @doc """
  Returns every idempotent-key ledger entry currently stored -- hash-only,
  matching what this table has always stored (the plaintext key is never
  persisted, only its hash, see hash/1). Backs drain mode's webhook flush
  (see EzthrottleLocal.DrainFlush) -- an opt-in feature, off by default, so
  this is only ever called on a deployment that has explicitly enabled it.
  """
  def list_ledger do
    {:atomic, entries} =
      :mnesia.transaction(fn ->
        :mnesia.select(@keys_table, [
          {{@keys_table, :"$1", :"$2", :_, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])
      end)

    Enum.map(entries, fn {hash, job_id, status} ->
      %{idempotent_key_hash: hash, job_id: job_id, status: status}
    end)
  end

  @doc """
  Wipes all three tables -- only ever called by drain mode's watchdog after
  a successful ledger-flush webhook delivery, never on a normal
  (non-drain-mode) deployment. Clears job_delivery_modes too, alongside the
  ledger and job tables, so a handoff doesn't leave orphaned rows behind.
  """
  def clear_ledger do
    :mnesia.clear_table(@keys_table)
    :mnesia.clear_table(@jobs_table)
    :mnesia.clear_table(@delivery_table)
    if flush_interval_ms() == 0, do: :mnesia.dump_log()
    :ok
  end

  @doc """
  Set delivery mode for a job. :webhook (default), :stream, :stream_fallback.
  """
  def set_delivery_mode(job_id, mode) do
    :mnesia.dirty_write({@delivery_table, job_id, mode})
    :ok
  end

  @doc """
  Get delivery mode for a job. Returns :webhook if not set.
  """
  def get_delivery_mode(job_id) do
    case :mnesia.dirty_read(@delivery_table, job_id) do
      [{@delivery_table, ^job_id, mode}] -> mode
      [] -> :webhook
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    schedule_cleanup()
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    spec = [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [:"$_"]}]

    delete_matching(@keys_table, spec)
    delete_matching(@jobs_table, spec)

    schedule_cleanup()
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
    case System.get_env("EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS") do
      nil ->
        @default_flush_interval_ms

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> @default_flush_interval_ms
        end
    end
  end

  defp delete_matching(table, spec) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.select(table, spec) end)

    :mnesia.transaction(fn ->
      Enum.each(rows, fn row -> :mnesia.delete_object(row) end)
    end)
  end

  # ---- Private ----

  # Scoped per user_id, matching Aquifer's hashKey(job.UserID + ":" + job.IdempotentKey) exactly --
  # without this, two different users submitting the same idempotent_key would collide with each
  # other (User B's request silently treated as a duplicate of User A's, never actually running).
  # This was a real porting gap, not a deliberate difference from Aquifer's documented contract
  # ("duplicate idempotent_key per user_id returns the existing job", README.md) -- found and fixed
  # while reviewing drain mode's ledger-hash documentation.
  defp hash_key(%Job{} = job), do: hash(job.user_id <> ":" <> job.idempotent_key)

  defp hash(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp ttl_ms(:completed), do: 30 * 60 * 1_000
  defp ttl_ms(:failed), do: 2 * 60 * 60 * 1_000
  defp ttl_ms(_), do: Application.get_env(:ezthrottle_local, :idempotent_ttl, 86_400) * 1_000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
