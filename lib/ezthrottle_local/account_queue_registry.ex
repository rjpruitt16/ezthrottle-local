defmodule EzthrottleLocal.AccountQueueRegistry do
  @moduledoc """
  Top-level registry for UrlActors.
  Routes incoming jobs to the correct UrlActor based on destination URL domain.
  Spawns UrlActors on demand and monitors them for cleanup.
  """

  use GenServer

  alias EzthrottleLocal.UrlActor
  alias EzthrottleLocal.Job
  alias EzthrottleLocal.PoolRegistry

  @table :url_actors

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Route a job to the correct UrlActor, spawning one if needed.
  account_queue_header is the raw X-Aqueduct-Account-Queue/
  X-EZThrottle-Account-Queue value from the originating request, or nil if
  this job has no live request behind it (e.g. recovered from Mnesia at
  startup). nil leaves the UrlActor's current account-queue mode
  unchanged rather than forcing it off — the mode is shared per upstream
  domain, so one request that doesn't care about it shouldn't be able to
  flip it off for every other concurrent tenant relying on it being on.
  """
  def enqueue(%Job{} = job, account_queue_header \\ nil) do
    GenServer.call(__MODULE__, {:enqueue, job, account_queue_header})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:enqueue, job, account_queue_header}, _from, state) do
    {route_key, pool_pid} = route_key_and_pool(job)

    pid =
      case :ets.lookup(@table, route_key) do
        [{^route_key, existing_pid}] ->
          existing_pid

        [] ->
          {:ok, new_pid} =
            UrlActor.start_link(url_key: route_key, domain: route_key, pool_pid: pool_pid)

          Process.monitor(new_pid)
          :ets.insert(@table, {route_key, new_pid})
          new_pid
      end

    if account_queue_header do
      mode = account_queue_header |> to_string() |> String.trim() |> String.downcase()

      case mode do
        "enabled" -> UrlActor.enable_account_queue(pid)
        "disabled" -> UrlActor.disable_account_queue(pid)
        _ -> :ok
      end
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

  # Pool-backed jobs route by pool_id instead of the destination domain,
  # since there is no single fixed domain -- PoolRegistry.get_or_create
  # lazily creates the pool if nobody's registered to it yet, so a
  # pool-backed job always gets pool-mode dispatch behavior (failing
  # cleanly with "no pool members registered" if empty) instead of
  # silently falling through to a non-pool dispatch path with no URL.
  defp route_key_and_pool(%Job{pool_id: pool_id}) when is_binary(pool_id) do
    {"pool:" <> pool_id, PoolRegistry.get_or_create(pool_id)}
  end

  defp route_key_and_pool(%Job{url: url}) do
    {url_key(url), nil}
  end
end
