defmodule EzthrottleLocal.UrlActor do
  @moduledoc """
  GenServer per destination URL domain.

  By default all traffic flows through a single shared queue for this URL.
  When X-EZTHROTTLE-ACCOUNT-QUEUE: enabled is received in a response header,
  the UrlActor switches to per-user AccountQueue isolation — one queue per
  user_id + api_key. This can also be enabled via config.

  AccountQueue mode is off by default. Enable it when you need per-user
  fairness and noisy neighbor isolation.
  """

  use GenServer

  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.Job

  @idle_timeout_ms 300_000
  @shared_queue_key :shared

  defstruct [
    :url_key,
    :domain,
    rps: 2.0,
    max_concurrent: 1,
    account_queue_enabled: false,
    queues: %{}
  ]

  # ---- Public API ----

  def start_link(opts) do
    url_key = Keyword.fetch!(opts, :url_key)
    domain = Keyword.fetch!(opts, :domain)
    GenServer.start_link(__MODULE__, %{url_key: url_key, domain: domain})
  end

  def enqueue(pid, %Job{} = job) do
    GenServer.call(pid, {:enqueue, job})
  end

  def update_rps(pid, rps) do
    GenServer.cast(pid, {:update_rps, rps})
  end

  def update_max_concurrent(pid, max) do
    GenServer.cast(pid, {:update_max_concurrent, max})
  end

  def enable_account_queue(pid) do
    GenServer.cast(pid, :enable_account_queue)
  end

  def disable_account_queue(pid) do
    GenServer.cast(pid, :disable_account_queue)
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{url_key: url_key, domain: domain}) do
    default_rps = Application.get_env(:ezthrottle_local, :default_rps, 2.0)
    account_queue_enabled = Application.get_env(:ezthrottle_local, :account_queue_enabled, false)

    state = %__MODULE__{
      url_key: url_key,
      domain: domain,
      rps: default_rps,
      account_queue_enabled: account_queue_enabled
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    queue_key = if state.account_queue_enabled do
      Job.queue_key(job)
    else
      @shared_queue_key
    end

    {queue_pid, new_state} = find_or_spawn_queue(queue_key, state)
    AccountQueue.enqueue(queue_pid, job)

    {:reply, :ok, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    Enum.each(state.queues, fn {_key, pid} ->
      AccountQueue.update_rps(pid, rps)
    end)
    {:noreply, %{state | rps: rps}, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:update_max_concurrent, max}, state) do
    Enum.each(state.queues, fn {_key, pid} ->
      AccountQueue.update_max_concurrent(pid, max)
    end)
    {:noreply, %{state | max_concurrent: max}, @idle_timeout_ms}
  end

  @impl true
  def handle_cast(:enable_account_queue, state) do
    {:noreply, %{state | account_queue_enabled: true}, @idle_timeout_ms}
  end

  @impl true
  def handle_cast(:disable_account_queue, state) do
    {:noreply, %{state | account_queue_enabled: false}, @idle_timeout_ms}
  end

  @impl true
  def handle_info({:account_queue_header, "enabled"}, state) do
    {:noreply, %{state | account_queue_enabled: true}, @idle_timeout_ms}
  end

  @impl true
  def handle_info({:account_queue_header, "disabled"}, state) do
    {:noreply, %{state | account_queue_enabled: false}, @idle_timeout_ms}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    queues = Enum.reject(state.queues, fn {_key, p} -> p == pid end) |> Map.new()
    {:noreply, %{state | queues: queues}, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    if map_size(state.queues) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_timeout_ms}
    end
  end

  # ---- Private ----

  defp find_or_spawn_queue(queue_key, state) do
    case Map.get(state.queues, queue_key) do
      nil ->
        {:ok, pid} = AccountQueue.start_link(
          queue_key: queue_key,
          rps: state.rps,
          max_concurrent: state.max_concurrent
        )
        Process.monitor(pid)
        new_state = %{state | queues: Map.put(state.queues, queue_key, pid)}
        {pid, new_state}

      pid ->
        {pid, state}
    end
  end
end
