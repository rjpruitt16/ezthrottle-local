defmodule EzthrottleLocal.IdempotentStore do
  @moduledoc """
  ETS-backed store for idempotent keys and full job structs with TTL.

  Two tables:
  - :idempotent_keys  — keyed by hashed idempotent_key, prevents duplicate execution
  - :jobs             — keyed by job_id, stores the full Job struct for status lookup

  Raw client keys are never stored — they are hashed before insertion.
  TTL defaults to 24 hours and is configurable via :idempotent_ttl.
  """

  use GenServer

  alias EzthrottleLocal.Job

  @keys_table :idempotent_keys
  @jobs_table :jobs
  @cleanup_interval_ms 60_000

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if an idempotent key already exists.
  If not, insert the full job into both tables.
  Returns :ok for new jobs or {:duplicate, existing_job_id} for known keys.
  """
  def check_or_insert(%Job{} = job) do
    hashed = hash(job.idempotent_key)
    expires_at = System.system_time(:millisecond) + ttl_ms(:queued)

    case :ets.lookup(@keys_table, hashed) do
      [{^hashed, existing_id, _expires_at, _status}] ->
        {:duplicate, existing_id}

      [] ->
        :ets.insert(@keys_table, {hashed, job.id, expires_at, :queued})
        :ets.insert(@jobs_table, {job.id, job, expires_at, :queued})
        :ok
    end
  end

  @doc """
  Update the status of a job by job_id in both tables.
  """
  def update_status(job_id, status) do
    case :ets.lookup(@jobs_table, job_id) do
      [{^job_id, job, _expires_at, _old_status}] ->
        new_expires = System.system_time(:millisecond) + ttl_ms(status)
        :ets.insert(@jobs_table, {job_id, job, new_expires, status})
        case :ets.match_object(@keys_table, {:_, job_id, :_, :_}) do
          [{hashed, ^job_id, _key_expires, _}] ->
            :ets.insert(@keys_table, {hashed, job_id, new_expires, status})
          _ -> :ok
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
    case :ets.lookup(@jobs_table, job_id) do
      [{^job_id, _job, _expires_at, status}] -> to_string(status)
      [] -> nil
    end
  end

  @doc """
  Get the full Job struct by job_id. Returns the Job or nil.
  """
  def get_job(job_id) do
    case :ets.lookup(@jobs_table, job_id) do
      [{^job_id, job, _expires_at, _status}] -> job
      [] -> nil
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    :ets.new(@keys_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@jobs_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    spec = [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@keys_table, spec)
    :ets.select_delete(@jobs_table, spec)
    schedule_cleanup()
    {:noreply, state}
  end

  # ---- Private ----

  defp hash(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp ttl_ms(:completed), do: 30 * 60 * 1_000
  defp ttl_ms(:failed),    do: 2 * 60 * 60 * 1_000
  defp ttl_ms(_),          do: Application.get_env(:ezthrottle_local, :idempotent_ttl, 86_400) * 1_000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
