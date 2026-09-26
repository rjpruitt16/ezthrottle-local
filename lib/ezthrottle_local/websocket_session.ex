defmodule EzthrottleLocal.WebSocketSession do
  @moduledoc false

  use GenServer

  require Logger

  alias EzthrottleLocal.{
    Jitter,
    WebSocketConfig,
    WebSocketProtocol,
    WebSocketQueue,
    WebSocketStore,
    WebSocketUpstream
  }

  @registry EzthrottleLocal.WebSocketSessionRegistry

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, session_id}})
  end

  def attach(pid, client, cursor), do: GenServer.call(pid, {:attach, client, cursor}, 30_000)
  def detach(pid, client), do: GenServer.cast(pid, {:detach, client})
  def command(pid, client, message), do: GenServer.call(pid, {:command, client, message}, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       session_id: Keyword.fetch!(opts, :session_id),
       upstream_url: Keyword.fetch!(opts, :upstream_url),
       upstream_headers: Keyword.get(opts, :upstream_headers, []),
       config: Keyword.get(opts, :config, WebSocketConfig.load()),
       clients: %{},
       upstream_pid: nil,
       upstream_monitor: nil,
       upstream_connected: false,
       queue_ref: nil,
       queue_token: nil,
       pending_commands: :queue.new(),
       reconnect_attempt: 0,
       reconnect_timer: nil,
       idle_timer: nil,
       generation: 0
     }}
  end

  @impl true
  def handle_call({:attach, client, cursor}, _from, state) do
    state = cancel_idle_timer(state)

    case replay(cursor, state) do
      {:ok, messages, final_cursor} ->
        monitor = Process.monitor(client)
        clients = Map.put(state.clients, client, %{monitor: monitor, cursor: final_cursor})
        state = %{state | clients: clients}
        send(self(), :ensure_upstream)
        {:reply, {:ok, messages}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, client, message}, _from, state) do
    if Map.has_key?(state.clients, client) do
      case WebSocketStore.append(state.session_id, "client", message) do
        {:ok, event} ->
          clients = advance_all_clients(state.clients, event.stream_id)
          pending = :queue.in(message, state.pending_commands)
          state = %{state | clients: clients, pending_commands: pending} |> flush_commands()

          reply = %{
            "type" => "command_recorded",
            "message_id" => message["message_id"],
            "stream_id" => event.stream_id
          }

          {:reply, {:ok, reply}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :client_not_attached}, state}
    end
  end

  @impl true
  def handle_cast({:detach, client}, state) do
    {:noreply, remove_client(state, client)}
  end

  @impl true
  def handle_info(:ensure_upstream, state) do
    cond do
      map_size(state.clients) == 0 ->
        {:noreply, state}

      state.upstream_pid || state.queue_ref || state.queue_token || state.reconnect_timer ->
        {:noreply, state}

      true ->
        case WebSocketQueue.enqueue(self()) do
          {:ok, ref, _position} -> {:noreply, %{state | queue_ref: ref}}
          {:error, reason} -> stop_clients(state, 1013, to_string(reason))
        end
    end
  end

  def handle_info({:websocket_waiting, ref, position}, %{queue_ref: ref} = state) do
    broadcast(state, %{"type" => "status", "state" => "waiting", "position" => position})
    {:noreply, state}
  end

  def handle_info({:websocket_waiting, _ref, _position}, state), do: {:noreply, state}

  def handle_info({:websocket_admitted, ref, token}, %{queue_ref: ref} = state) do
    broadcast(state, %{"type" => "status", "state" => "connecting"})
    send(self(), :connect_upstream)
    {:noreply, %{state | queue_ref: nil, queue_token: token}}
  end

  def handle_info({:websocket_admitted, _ref, token}, state) do
    WebSocketQueue.release(token)
    {:noreply, state}
  end

  def handle_info(:connect_upstream, state) do
    case WebSocketUpstream.start(
           state.upstream_url,
           self(),
           state.upstream_headers,
           state.config.handshake_timeout_ms
         ) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        {:noreply,
         %{state | upstream_pid: pid, upstream_monitor: monitor, upstream_connected: false}}

      {:error, reason} ->
        WebSocketQueue.report_failure()
        state = release_upstream_slot(state)
        {:noreply, schedule_reconnect(state, reason)}
    end
  end

  def handle_info({:websocket_upstream_connected, pid, headers}, %{upstream_pid: pid} = state) do
    apply_capacity_headers(headers)
    WebSocketQueue.report_success()
    generation = WebSocketQueue.next_generation()

    broadcast(state, %{
      "type" => "status",
      "state" => "connected",
      "generation" => generation
    })

    state = %{
      state
      | upstream_connected: true,
        reconnect_attempt: 0,
        generation: generation
    }

    {:noreply, flush_commands(state)}
  end

  def handle_info({:websocket_upstream_connected, _pid, _headers}, state), do: {:noreply, state}

  def handle_info({:websocket_upstream_frame, pid, raw}, %{upstream_pid: pid} = state) do
    case WebSocketProtocol.decode_backend(raw) do
      {:ok, %{"type" => "aqueduct.capacity"} = message} ->
        WebSocketQueue.update_capacity(message["max_connections"], message["connect_rps"])
        {:noreply, state}

      {:ok, message} ->
        message = Map.put(message, "generation", state.generation)

        case WebSocketStore.append(state.session_id, "backend", message) do
          {:ok, event} ->
            {:noreply, deliver_event(state, event)}

          {:error, reason} ->
            stop_clients(state, 1011, "event store unavailable: #{inspect(reason)}")
        end

      {:error, reason} ->
        WebSocketUpstream.close(pid)
        {:noreply, state |> notify_error(reason)}
    end
  end

  def handle_info({:websocket_upstream_frame, _pid, _raw}, state), do: {:noreply, state}

  def handle_info({:websocket_upstream_error, pid, reason}, %{upstream_pid: pid} = state) do
    WebSocketUpstream.close(pid)
    {:noreply, notify_error(state, reason)}
  end

  def handle_info({:websocket_upstream_disconnected, pid, reason}, %{upstream_pid: pid} = state) do
    {:noreply, upstream_disconnected(state, reason)}
  end

  def handle_info({:websocket_upstream_disconnected, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}
    send(self(), :ensure_upstream)
    {:noreply, state}
  end

  def handle_info(:idle_timeout, %{clients: clients} = state) when map_size(clients) == 0 do
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state), do: {:noreply, %{state | idle_timer: nil}}

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      state.upstream_monitor == monitor and state.upstream_pid == pid ->
        {:noreply, upstream_disconnected(state, reason)}

      true ->
        case Enum.find(state.clients, fn {_client, info} -> info.monitor == monitor end) do
          {client, _info} -> {:noreply, remove_client(state, client, false)}
          nil -> {:noreply, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.queue_ref, do: WebSocketQueue.cancel(state.queue_ref)
    if state.queue_token, do: WebSocketQueue.release(state.queue_token)
    if state.upstream_pid, do: WebSocketUpstream.close(state.upstream_pid)
    :ok
  end

  defp replay(cursor, state) do
    messages = [%{"type" => "status", "state" => "replaying"}]

    case read_replay_pages(state.session_id, cursor, state.config.read_batch, [], cursor) do
      {:ok, events, final_cursor} ->
        replayed =
          events
          |> Enum.filter(&(&1.direction == "backend"))
          |> Enum.map(&Map.put(&1.envelope, "stream_id", &1.stream_id))

        {:ok, messages ++ replayed ++ [%{"type" => "status", "state" => "replay_complete"}],
         final_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_replay_pages(session_id, cursor, batch, collected, final_cursor) do
    case WebSocketStore.read_after(session_id, cursor, batch) do
      {:ok, []} ->
        {:ok, Enum.reverse(collected), final_cursor}

      {:ok, events} ->
        newest = List.last(events).stream_id
        collected = Enum.reverse(events, collected)

        if length(events) < batch do
          {:ok, Enum.reverse(collected), newest}
        else
          read_replay_pages(session_id, newest, batch, collected, newest)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_event(state, event) do
    message = Map.put(event.envelope, "stream_id", event.stream_id)

    clients =
      Map.new(state.clients, fn {client, info} ->
        if cursor_before?(info.cursor, event.stream_id) do
          send(client, {:websocket_push, message})
          {client, %{info | cursor: event.stream_id}}
        else
          {client, info}
        end
      end)

    %{state | clients: clients}
  end

  defp advance_all_clients(clients, cursor) do
    Map.new(clients, fn {client, info} -> {client, %{info | cursor: cursor}} end)
  end

  defp cursor_before?(left, right) do
    case WebSocketStore.compare_cursors(left, right) do
      {:ok, :lt} -> true
      _ -> false
    end
  end

  defp flush_commands(%{upstream_connected: true, upstream_pid: pid} = state) when is_pid(pid) do
    case :queue.out(state.pending_commands) do
      {{:value, message}, rest} ->
        WebSocketUpstream.send_message(pid, message)
        flush_commands(%{state | pending_commands: rest})

      {:empty, _queue} ->
        state
    end
  end

  defp flush_commands(state), do: state

  defp upstream_disconnected(%{upstream_pid: nil} = state, _reason), do: state

  defp upstream_disconnected(state, reason) do
    was_connected = state.upstream_connected

    Logger.debug(
      "WebSocket session #{state.session_id} upstream disconnected: #{inspect(reason)}"
    )

    if state.upstream_monitor, do: Process.demonitor(state.upstream_monitor, [:flush])
    state = release_upstream_slot(state)

    state = %{
      state
      | upstream_pid: nil,
        upstream_monitor: nil,
        upstream_connected: false
    }

    unless was_connected, do: WebSocketQueue.report_failure()
    schedule_reconnect(state, reason)
  end

  defp release_upstream_slot(%{queue_token: nil} = state), do: state

  defp release_upstream_slot(state) do
    WebSocketQueue.release(state.queue_token)
    %{state | queue_token: nil}
  end

  defp schedule_reconnect(state, reason) do
    if map_size(state.clients) == 0 do
      state
    else
      attempt = state.reconnect_attempt + 1
      base = min(round(:math.pow(2, attempt - 1) * 1_000), state.config.reconnect_max_ms)
      delay = Jitter.add_ms(base)

      Logger.debug(
        "WebSocket session #{state.session_id} reconnecting in #{delay}ms (attempt #{attempt})"
      )

      broadcast(state, %{
        "type" => "status",
        "state" => "reconnecting",
        "reason" => inspect(reason),
        "retry_after_ms" => delay
      })

      if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

      %{
        state
        | reconnect_attempt: attempt,
          reconnect_timer: Process.send_after(self(), :reconnect, delay)
      }
    end
  end

  defp apply_capacity_headers(headers) do
    headers =
      Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)

    max_connections = parse_positive_integer(headers["x-aqueduct-ws-max-connections"])
    connect_rps = parse_positive_float(headers["x-aqueduct-ws-connect-rps"])
    WebSocketQueue.update_capacity(max_connections, connect_rps)
  end

  defp parse_positive_integer(nil), do: nil

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_float(nil), do: nil

  defp parse_positive_float(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp remove_client(state, client, demonitor? \\ true) do
    case Map.pop(state.clients, client) do
      {nil, _clients} ->
        state

      {info, clients} ->
        if demonitor?, do: Process.demonitor(info.monitor, [:flush])
        state = %{state | clients: clients}

        if map_size(clients) == 0 do
          state = quiesce_upstream(state)
          timer = Process.send_after(self(), :idle_timeout, state.config.idle_timeout_ms)
          %{state | idle_timer: timer}
        else
          state
        end
    end
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(state) do
    Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp quiesce_upstream(state) do
    if state.queue_ref, do: WebSocketQueue.cancel(state.queue_ref)
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    if state.upstream_monitor, do: Process.demonitor(state.upstream_monitor, [:flush])
    if state.upstream_pid, do: WebSocketUpstream.close(state.upstream_pid)

    state
    |> release_upstream_slot()
    |> Map.merge(%{
      upstream_pid: nil,
      upstream_monitor: nil,
      upstream_connected: false,
      queue_ref: nil,
      reconnect_timer: nil,
      reconnect_attempt: 0,
      pending_commands: :queue.new()
    })
  end

  defp broadcast(state, message) do
    Enum.each(Map.keys(state.clients), &send(&1, {:websocket_push, message}))
  end

  defp notify_error(state, reason) do
    broadcast(state, %{"type" => "error", "reason" => to_string(reason)})
    state
  end

  defp stop_clients(state, code, reason) do
    Enum.each(Map.keys(state.clients), &send(&1, {:websocket_close, code, reason}))
    {:stop, reason, state}
  end
end
