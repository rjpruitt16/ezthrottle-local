defmodule EzthrottleLocal.WebSocketQueue do
  @moduledoc """
  Per-node FIFO admission queue for upstream WebSocket connections.

  Connection openings are jittered and slow-started independently from HTTP
  request pacing. Backend capacity signals may lower, but never raise, the
  operator-configured connection and rate ceilings.
  """

  use GenServer

  alias EzthrottleLocal.{Jitter, WebSocketConfig}

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def reserve_client, do: GenServer.call(__MODULE__, :reserve_client)
  def release_client(token), do: GenServer.cast(__MODULE__, {:release_client, token})
  def enqueue(pid), do: GenServer.call(__MODULE__, {:enqueue, pid})
  def cancel(ref), do: GenServer.cast(__MODULE__, {:cancel, ref})
  def release(token), do: GenServer.cast(__MODULE__, {:release, token})
  def report_success, do: GenServer.cast(__MODULE__, :report_success)
  def report_failure, do: GenServer.cast(__MODULE__, :report_failure)

  def update_capacity(max_connections, connect_rps),
    do: GenServer.cast(__MODULE__, {:update_capacity, max_connections, connect_rps})

  def next_generation, do: GenServer.call(__MODULE__, :next_generation)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(%WebSocketConfig{} = config) do
    {:ok,
     %{
       config: config,
       client_tokens: MapSet.new(),
       waiters: [],
       active: %{},
       advertised_max: nil,
       advertised_rps: nil,
       ramp_rps: config.slow_start_rps,
       next_grant_ms: monotonic_ms(),
       timer: nil,
       generation: 0
     }}
  end

  @impl true
  def handle_call(:reserve_client, _from, state) do
    if MapSet.size(state.client_tokens) >= state.config.max_clients do
      {:reply, {:error, :client_limit}, state}
    else
      token = make_ref()
      {:reply, {:ok, token}, %{state | client_tokens: MapSet.put(state.client_tokens, token)}}
    end
  end

  def handle_call({:enqueue, pid}, _from, state) do
    if length(state.waiters) >= state.config.max_waiting do
      {:reply, {:error, :waiting_limit}, state}
    else
      ref = make_ref()
      monitor = Process.monitor(pid)
      position = length(state.waiters) + 1
      waiter = %{ref: ref, pid: pid, monitor: monitor, position: position}
      send(pid, {:websocket_waiting, ref, position})
      state = %{state | waiters: state.waiters ++ [waiter]} |> schedule()
      {:reply, {:ok, ref, position}, state}
    end
  end

  def handle_call(:next_generation, _from, state) do
    generation = state.generation + 1
    {:reply, generation, %{state | generation: generation}}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      enabled: state.config.enabled,
      clients: MapSet.size(state.client_tokens),
      active_upstreams: map_size(state.active),
      waiting: length(state.waiters),
      max_client_connections: state.config.max_clients,
      max_upstream_connections: state.config.max_upstreams,
      effective_max_upstreams: effective_max(state),
      connect_rps: state.config.connect_rps,
      slow_start_rps: state.config.slow_start_rps,
      current_ramp_rps: state.ramp_rps,
      effective_connect_rps: effective_rps(state)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:release_client, token}, state) do
    {:noreply, %{state | client_tokens: MapSet.delete(state.client_tokens, token)}}
  end

  def handle_cast({:cancel, ref}, state) do
    {removed, waiters} = pop_waiter(state.waiters, ref)
    if removed, do: Process.demonitor(removed.monitor, [:flush])
    state = %{state | waiters: publish_positions(waiters)} |> schedule()
    {:noreply, state}
  end

  def handle_cast({:release, token}, state) do
    {waiter, active} = Map.pop(state.active, token)
    if waiter, do: Process.demonitor(waiter.monitor, [:flush])
    {:noreply, %{state | active: active} |> schedule()}
  end

  def handle_cast(:report_success, state) do
    ramp = min(state.ramp_rps * 2, state.config.connect_rps)
    {:noreply, %{state | ramp_rps: ramp} |> schedule()}
  end

  def handle_cast(:report_failure, state) do
    interval = interval_ms(%{state | ramp_rps: state.config.slow_start_rps})
    earliest = monotonic_ms() + Jitter.add_ms(interval)

    state = %{
      state
      | ramp_rps: state.config.slow_start_rps,
        next_grant_ms: max(state.next_grant_ms, earliest)
    }

    {:noreply, schedule(state)}
  end

  def handle_cast({:update_capacity, max_connections, connect_rps}, state) do
    state = %{
      state
      | advertised_max: positive_or_existing(max_connections, state.advertised_max),
        advertised_rps: positive_or_existing(connect_rps, state.advertised_rps)
    }

    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:grant, state) do
    {:noreply, schedule(%{state | timer: nil})}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    waiters = Enum.reject(state.waiters, &(&1.monitor == monitor))

    active =
      state.active
      |> Enum.reject(fn {_token, waiter} -> waiter.monitor == monitor end)
      |> Map.new()

    {:noreply, %{state | waiters: publish_positions(waiters), active: active} |> schedule()}
  end

  defp schedule(state) do
    state = cancel_timer(state)

    cond do
      state.waiters == [] or map_size(state.active) >= effective_max(state) ->
        state

      state.next_grant_ms <= monotonic_ms() ->
        [waiter | rest] = state.waiters
        token = make_ref()
        send(waiter.pid, {:websocket_admitted, waiter.ref, token})

        state = %{
          state
          | waiters: publish_positions(rest),
            active: Map.put(state.active, token, waiter),
            next_grant_ms: monotonic_ms() + Jitter.add_ms(interval_ms(state))
        }

        schedule(state)

      true ->
        delay = max(state.next_grant_ms - monotonic_ms(), 1)
        %{state | timer: Process.send_after(self(), :grant, delay)}
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)

    receive do
      :grant -> :ok
    after
      0 -> :ok
    end

    %{state | timer: nil}
  end

  defp effective_max(state) do
    case state.advertised_max do
      value when is_integer(value) and value > 0 -> min(value, state.config.max_upstreams)
      _ -> state.config.max_upstreams
    end
  end

  defp effective_rps(state) do
    [state.config.connect_rps, state.ramp_rps, state.advertised_rps]
    |> Enum.filter(&(is_number(&1) and &1 > 0))
    |> Enum.min()
  end

  defp interval_ms(state), do: max(round(1_000 / effective_rps(state)), 1)

  defp publish_positions(waiters) do
    Enum.with_index(waiters, 1)
    |> Enum.map(fn {waiter, position} ->
      if waiter.position != position do
        send(waiter.pid, {:websocket_waiting, waiter.ref, position})
      end

      %{waiter | position: position}
    end)
  end

  defp pop_waiter(waiters, ref) do
    case Enum.split_while(waiters, &(&1.ref != ref)) do
      {before, [waiter | after_waiter]} -> {waiter, before ++ after_waiter}
      {_before, []} -> {nil, waiters}
    end
  end

  defp positive_or_existing(value, _existing) when is_number(value) and value > 0, do: value
  defp positive_or_existing(_value, existing), do: existing
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
