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

    uri = URI.parse(url)

    options =
      if uri.scheme == "wss" do
        Keyword.merge(options, insecure: false, cacerts: :public_key.cacerts_get())
      else
        options ++ socket_family_options(uri.host)
      end

    WebSockex.start(url, __MODULE__, %{owner: owner}, options)
  end

  @doc """
  TCP options for reaching `host` over ws://. WebSockex connects with plain
  gen_tcp, which resolves IPv4 only, so a host with only an IPv6 address
  (an IPv6 literal, or a name like Fly's `*.internal` private network) was
  unreachable and every session sat in "reconnecting". Such hosts connect
  over IPv6; hosts with an IPv4 address keep connecting as before.
  """
  def socket_family_options(host) when is_binary(host) do
    if ipv6_only?(String.trim(host, "[") |> String.trim("]")),
      do: [socket_options: [tcp_module: :inet6_tcp]],
      else: []
  end

  def socket_family_options(_host), do: []

  defp ipv6_only?(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        tuple_size(address) == 8

      {:error, _} ->
        not match?({:ok, _}, :inet.getaddr(charlist, :inet)) and
          match?({:ok, _}, :inet.getaddr(charlist, :inet6))
    end
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
