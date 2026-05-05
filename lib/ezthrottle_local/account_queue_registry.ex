defmodule EzthrottleLocal.AccountQueueRegistry do
  @moduledoc """
  Top-level registry for UrlActors.
  Routes incoming jobs to the correct UrlActor based on destination URL domain.
  Spawns UrlActors on demand and monitors them for cleanup.
  """

  use GenServer

  alias EzthrottleLocal.UrlActor
  alias EzthrottleLocal.Job

  @table :url_actors

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Route a job to the correct UrlActor, spawning one if needed.
  """
  def enqueue(%Job{} = job) do
    GenServer.call(__MODULE__, {:enqueue, job})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    url_key = url_key(job.url)

    pid = case :ets.lookup(@table, url_key) do
      [{^url_key, existing_pid}] ->
        existing_pid

      [] ->
        {:ok, new_pid} = UrlActor.start_link(url_key: url_key, domain: url_key)
        Process.monitor(new_pid)
        :ets.insert(@table, {url_key, new_pid})
        new_pid
    end

    UrlActor.enqueue(pid, job)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {:_, pid})
    {:noreply, state}
  end

  # ---- Private ----

  defp url_key(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}"
  end
end
