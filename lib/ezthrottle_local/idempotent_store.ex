defmodule EzthrottleLocal.IdempotentStore do
  @moduledoc """
  ETS-backed store for idempotent keys with TTL.
  Prevents duplicate job execution when the same idempotent_key is submitted twice.

  Raw client keys are never stored — they are hashed before insertion.
  TTL defaults to 24 hours and is configurable via EZTHROTTLE_IDEMPOTENT_TTL.
  """

  use GenServer

  @table :idempotent_keys
  @cleanup_interval_ms 60_000

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if an idempotent key already exists.
  If not, insert it with the given job_id and TTL.
  Returns :ok for new keys or {:duplicate, existing_job_id} for known keys.
  """
  def check_or_insert(idempotent_key, job_id) do
    hashed = hash(idempotent_key)
    expires_at = System.system_time(:millisecond) + ttl_ms()

    case :ets.lookup(@table, hashed) do
      [{^hashed, existing_id, _expires_at, _status}] ->
        {:duplicate, existing_id}

      [] ->
        :ets.insert(@table, {hashed, job_id, expires_at, :queued})
        :ok
    end
  end

  @doc """
  Update the status of a job by job_id.
  Used by AccountQueue to mark jobs completed or failed.
  """
  def update_status(job_id, status) do
    case :ets.match_object(@table, {:_, job_id, :_, :_}) do
      [{hashed, ^job_id, expires_at, _old_status}] ->
        :ets.insert(@table, {hashed, job_id, expires_at, status})
        :ok

      [] ->
        :error
    end
  end

  @doc """
  Get the status of a job by job_id.
  Returns the status string or nil if not found.
  """
  def get_status(job_id) do
    case :ets.match_object(@table, {:_, job_id, :_, :_}) do
      [{_hashed, ^job_id, _expires_at, status}] -> to_string(status)
      _ -> nil
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  # ---- Private ----

  defp hash(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp ttl_ms do
    ttl_seconds = Application.get_env(:ezthrottle_local, :idempotent_ttl, 86_400)
    ttl_seconds * 1_000
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
