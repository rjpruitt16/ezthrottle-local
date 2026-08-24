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
  alias EzthrottleLocal.DrainFlush

  @table :url_actors
  @idle_check_interval_ms 5_000

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

    # Drain mode's watchdog: only scheduled at all if enabled?/0 is true at
    # startup -- disabled means exactly that no periodic check ever runs,
    # not a check that runs and no-ops. See EzthrottleLocal.DrainFlush.
    if DrainFlush.enabled?() do
      schedule_idle_check()
    end

    {:ok, %{became_idle_at: nil, handled: false}}
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

  @impl true
  def handle_info(:idle_check, state) do
    idle? = :ets.info(@table, :size) == 0
    new_state = check_idle(idle?, state)
    schedule_idle_check()
    {:noreply, new_state}
  end

  # ---- Private ----

  # Mirrors Aquifer's drainWatchdogLoop: not idle resets bookkeeping; newly
  # idle just records the timestamp; already-handled this idle period skips
  # a re-flush; otherwise, once idle long enough, attempts a flush -- a
  # failure leaves handled: false so the next tick retries from scratch,
  # safely, since a failed attempt never clears anything.
  defp check_idle(false, _state), do: %{became_idle_at: nil, handled: false}

  defp check_idle(true, %{became_idle_at: nil}) do
    %{became_idle_at: System.monotonic_time(:millisecond), handled: false}
  end

  defp check_idle(true, %{handled: true} = state), do: state

  defp check_idle(true, %{became_idle_at: became_idle_at} = state) do
    elapsed_ms = System.monotonic_time(:millisecond) - became_idle_at

    if elapsed_ms >= DrainFlush.timer_seconds() * 1_000 do
      %{state | handled: DrainFlush.attempt()}
    else
      state
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_check_interval_ms)
  end

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
