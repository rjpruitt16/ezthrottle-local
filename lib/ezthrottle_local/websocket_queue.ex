defmodule EzthrottleLocal.WebSocketQueue do
  @moduledoc """
  Per-node FIFO admission queue for upstream WebSocket connections.

  Connection openings are jittered and slow-started independently from HTTP
  request pacing. Backend capacity signals may lower, but never raise, the
  operator-configured connection and rate ceilings.

  Grants are paced by GCRA (a virtual-time token bucket), so each timer
  tick admits every waiter the elapsed time allows. Each grant pushes the
  next allowed time out by one interval at the rate in force when it is
  granted, so a rate rise (the slow-start ramp doubling after a successful
  handshake) shortens later gaps, never the one already started: with
  slow start at 1/s the second connection still waits a full second. Granting one
  waiter per tick, spaced by a whole-millisecond interval plus at least
  1 ms of jitter, capped admission near 500/s whatever the configured rate,
  and the Fly lab measured about 240/s. Jitter now applies to when the next
  tick fires.

  Waiters hold a place in a `:queue`. Positions are recomputed and sent at
  most once a second (only to waiters whose position changed), not
  on every grant: renumbering every waiter on every grant sent each of
  10,000 waiting sessions a status frame per admission, about 50M messages
  to drain the line.
  """

  use GenServer

  alias EzthrottleLocal.{Jitter, WebSocketConfig}

  @position_interval_ms 1_000
  # The bucket holds at most this much time's worth of grants, so an idle
  # queue can't save up a burst larger than ~100 ms of the rate.
  @burst_ms 100

  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, name: Keyword.get(opts, :name, __MODULE__))
  end

  def reserve_client(server \\ __MODULE__), do: GenServer.call(server, :reserve_client)

  def release_client(token, server \\ __MODULE__),
    do: GenServer.cast(server, {:release_client, token})

  def enqueue(pid, server \\ __MODULE__), do: GenServer.call(server, {:enqueue, pid})
  def cancel(ref, server \\ __MODULE__), do: GenServer.cast(server, {:cancel, ref})
  def release(token, server \\ __MODULE__), do: GenServer.cast(server, {:release, token})
  def report_success(server \\ __MODULE__), do: GenServer.cast(server, :report_success)
  def report_failure(server \\ __MODULE__), do: GenServer.cast(server, :report_failure)

  def update_capacity(max_connections, connect_rps, server \\ __MODULE__),
    do: GenServer.cast(server, {:update_capacity, max_connections, connect_rps})

  def next_generation(server \\ __MODULE__), do: GenServer.call(server, :next_generation)
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(%WebSocketConfig{} = config) do
    now = monotonic_ms()

    {:ok,
     %{
       config: config,
       client_tokens: MapSet.new(),
       # FIFO of waiter refs; a cancelled waiter's ref stays until it
       # reaches the front and is skipped.
       order: :queue.new(),
       waiting: %{},
       active: %{},
       # monitor ref -> {:waiting, ref} | {:active, token}
       monitors: %{},
       advertised_max: nil,
       advertised_rps: nil,
       ramp_rps: config.slow_start_rps,
       # Theoretical arrival time: grants may run ahead of it by at most
       # the burst tolerance. A failed handshake's backoff pushes it out.
       tat: now,
       timer: nil,
       position_timer: nil,
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
    if map_size(state.waiting) >= state.config.max_waiting do
      {:reply, {:error, :waiting_limit}, state}
    else
      ref = make_ref()
      position = map_size(state.waiting) + 1
      monitor = Process.monitor(pid)
      waiter = %{pid: pid, monitor: monitor, position: position}
      send(pid, {:websocket_waiting, ref, position})

      state =
        %{
          state
          | order: :queue.in(ref, state.order),
            waiting: Map.put(state.waiting, ref, waiter),
            monitors: Map.put(state.monitors, monitor, {:waiting, ref})
        }
        |> schedule()
        |> schedule_positions()

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
      waiting: map_size(state.waiting),
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
    {waiter, waiting} = Map.pop(state.waiting, ref)
    {:noreply, %{state | waiting: waiting} |> forget(waiter) |> schedule()}
  end

  def handle_cast({:release, token}, state) do
    {waiter, active} = Map.pop(state.active, token)
    {:noreply, %{state | active: active} |> forget(waiter) |> schedule()}
  end

  def handle_cast(:report_success, state) do
    ramp = min(state.ramp_rps * 2, state.config.connect_rps)
    {:noreply, %{state | ramp_rps: ramp} |> schedule()}
  end

  def handle_cast(:report_failure, state) do
    state = %{state | ramp_rps: state.config.slow_start_rps}
    backoff = Jitter.add_ms(max(round(1_000 / effective_rps(state)), 1))
    # Past the burst tolerance too, so nothing is granted before the backoff ends.
    tat = monotonic_ms() + backoff + tolerance_ms(state)
    {:noreply, schedule(%{state | tat: max(state.tat, tat)})}
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

  def handle_info(:publish_positions, state) do
    {:noreply, %{state | position_timer: nil} |> publish_positions() |> schedule_positions()}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {entry, monitors} = Map.pop(state.monitors, monitor)
    state = %{state | monitors: monitors}

    state =
      case entry do
        {:waiting, ref} -> %{state | waiting: Map.delete(state.waiting, ref)}
        {:active, token} -> %{state | active: Map.delete(state.active, token)}
        nil -> state
      end

    {:noreply, schedule(state)}
  end

  defp forget(state, nil), do: state

  defp forget(state, waiter) do
    Process.demonitor(waiter.monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, waiter.monitor)}
  end

  # ---- granting ----

  defp schedule(state) do
    state = cancel_timer(state)
    now = monotonic_ms()
    earliest = state.tat - tolerance_ms(state)

    cond do
      map_size(state.waiting) == 0 or map_size(state.active) >= effective_max(state) ->
        state

      now >= earliest ->
        state |> grant(now) |> schedule()

      true ->
        # Jitter spreads ticks so nodes started together don't open
        # connections in lockstep.
        timer(state, Jitter.add_ms(max(ceil(earliest - now), 1)))
    end
  end

  defp grant(state, now) do
    case :queue.out(state.order) do
      {{:value, ref}, order} ->
        case Map.pop(state.waiting, ref) do
          {nil, _waiting} ->
            # Cancelled while waiting.
            %{state | order: order}

          {waiter, waiting} ->
            token = make_ref()
            send(waiter.pid, {:websocket_admitted, ref, token})

            %{
              state
              | order: order,
                waiting: waiting,
                active: Map.put(state.active, token, waiter),
                monitors: Map.put(state.monitors, waiter.monitor, {:active, token}),
                tat: max(state.tat, now) + interval_ms(state)
            }
        end

      {:empty, _order} ->
        %{state | waiting: %{}}
    end
  end

  defp interval_ms(state), do: 1_000 / effective_rps(state)

  # How far grants may run ahead of the paced schedule: @burst_ms worth of
  # the rate, less the one grant every schedule allows anyway. Zero at
  # rates of 10/s or less, so slow start is strictly one per interval.
  defp tolerance_ms(state), do: max(@burst_ms - interval_ms(state), 0)

  defp timer(state, delay), do: %{state | timer: Process.send_after(self(), :grant, delay)}

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

  # ---- positions ----

  defp schedule_positions(%{position_timer: nil} = state) when map_size(state.waiting) > 0 do
    %{
      state
      | position_timer: Process.send_after(self(), :publish_positions, @position_interval_ms)
    }
  end

  defp schedule_positions(state), do: state

  # Walks the line once, dropping cancelled refs, and tells each waiter its
  # position only if it changed since the last update.
  defp publish_positions(state) do
    {order, waiting, _position} =
      state.order
      |> :queue.to_list()
      |> Enum.reduce({:queue.new(), state.waiting, 1}, fn ref, {order, waiting, position} ->
        case Map.fetch(waiting, ref) do
          {:ok, waiter} ->
            waiter =
              if waiter.position != position do
                send(waiter.pid, {:websocket_waiting, ref, position})
                %{waiter | position: position}
              else
                waiter
              end

            {:queue.in(ref, order), Map.put(waiting, ref, waiter), position + 1}

          :error ->
            {order, waiting, position}
        end
      end)

    %{state | order: order, waiting: waiting}
  end

  # ---- limits ----

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

  defp positive_or_existing(value, _existing) when is_number(value) and value > 0, do: value
  defp positive_or_existing(_value, existing), do: existing
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
