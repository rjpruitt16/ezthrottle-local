defmodule EzthrottleLocal.WebSocketUpstream do
  @moduledoc false

  use WebSockex

  alias EzthrottleLocal.WebSocketProtocol

  def start(url, owner, headers, timeout_ms) do
    headers = [{"Sec-WebSocket-Protocol", WebSocketProtocol.subprotocol()} | headers]

    options = [
      extra_headers: headers,
      socket_connect_timeout: timeout_ms,
      socket_recv_timeout: timeout_ms
    ]

    options =
      if URI.parse(url).scheme == "wss" do
        Keyword.merge(options, insecure: false, cacerts: :public_key.cacerts_get())
      else
        options
      end

    WebSockex.start(url, __MODULE__, %{owner: owner}, options)
  end

  def send_message(pid, message) do
    WebSockex.cast(pid, {:send, WebSocketProtocol.encode(message)})
  end

  def close(pid), do: WebSockex.cast(pid, :close)

  @impl true
  def handle_connect(conn, state) do
    send(state.owner, {:websocket_upstream_connected, self(), conn.resp_headers})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    send(state.owner, {:websocket_upstream_frame, self(), raw})
    {:ok, state}
  end

  def handle_frame({:binary, _raw}, state) do
    send(state.owner, {:websocket_upstream_error, self(), :binary_frames_not_supported})
    {:close, {1003, "aqueduct.v1 requires JSON text messages"}, state}
  end

  @impl true
  def handle_cast({:send, raw}, state), do: {:reply, {:text, raw}, state}
  def handle_cast(:close, state), do: {:close, {1000, "session closed"}, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.owner, {:websocket_upstream_disconnected, self(), status.reason})
    {:ok, state}
  end
end
