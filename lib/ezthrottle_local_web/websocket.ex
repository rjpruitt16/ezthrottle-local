defmodule EzthrottleLocalWeb.WebSocket do
  @moduledoc false

  @behaviour WebSock

  alias EzthrottleLocal.{
    WebSocketProtocol,
    WebSocketQueue,
    WebSocketSession,
    WebSocketSessionSupervisor
  }

  @impl true
  def init(initial) do
    opts = [
      session_id: initial.session_id,
      upstream_url: initial.upstream_url,
      upstream_headers: initial.upstream_headers,
      config: initial.config
    ]

    with {:ok, session} <- WebSocketSessionSupervisor.get_or_start(opts),
         {:ok, messages} <- WebSocketSession.attach(session, self(), initial.cursor) do
      monitor = Process.monitor(session)
      state = Map.merge(initial, %{session: session, session_monitor: monitor})
      {:push, Enum.map(messages, &text_frame/1), state}
    else
      {:error, reason} ->
        WebSocketQueue.release_client(initial.client_token)
        {:stop, reason, {1011, "websocket session unavailable"}, initial}
    end
  end

  @impl true
  def handle_in({raw, opcode: :text}, state) do
    with {:ok, message} <- WebSocketProtocol.decode_client(raw),
         {:ok, recorded} <- WebSocketSession.command(state.session, self(), message) do
      {:push, text_frame(recorded), state}
    else
      {:error, reason} ->
        {:push, text_frame(%{"type" => "error", "reason" => error_message(reason)}), state}
    end
  end

  def handle_in({_raw, opcode: :binary}, state) do
    {:push,
     text_frame(%{"type" => "error", "reason" => "aqueduct.v1 requires JSON text messages"}),
     state}
  end

  @impl true
  def handle_info({:websocket_push, message}, state), do: {:push, text_frame(message), state}

  def handle_info({:websocket_close, code, reason}, state),
    do: {:stop, reason, {code, reason}, state}

  def handle_info(
        {:DOWN, monitor, :process, session, reason},
        %{session_monitor: monitor, session: session} = state
      ),
      do: {:stop, reason, {1011, "websocket session stopped"}, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if session = Map.get(state, :session), do: WebSocketSession.detach(session, self())
    if monitor = Map.get(state, :session_monitor), do: Process.demonitor(monitor, [:flush])
    WebSocketQueue.release_client(state.client_token)
    :ok
  end

  defp text_frame(message), do: {:text, WebSocketProtocol.encode(message)}
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
