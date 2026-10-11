defmodule EzthrottleLocal.WebSocketUpstream do
  @moduledoc """
  One WebSocket connection to a session's backend.

  The socket is read one chunk at a time: a chunk's frames are handed to
  the session with a call, which returns once the session has recorded
  them, and only then is the socket armed for the next chunk. While the
  session is busy nothing more is read, the kernel buffers fill, and TCP
  slows the backend down. WebSockex, used before, kept its socket in
  `active: true`, so the VM read everything the backend sent into the
  session's mailbox; under overload that mailbox grew by 5-10 MB/s until
  the node ran out of memory (#24).
  """

  use GenServer

  alias EzthrottleLocal.WebSocketProtocol

  def start(url, owner, headers, timeout_ms) do
    GenServer.start(__MODULE__, {url, owner, headers, timeout_ms})
  end

  def send_message(pid, message) do
    GenServer.cast(pid, {:send, WebSocketProtocol.encode(message)})
  end

  def close(pid), do: GenServer.cast(pid, :close)

  @doc """
  TCP options for reaching `host` over ws://. Plain gen_tcp resolves IPv4
  only, so a host with only an IPv6 address (an IPv6 literal, or a name
  like Fly's `*.internal` private network) was unreachable and every
  session sat in "reconnecting". Such hosts connect over IPv6; hosts with
  an IPv4 address keep connecting as before.
  """
  def socket_family_options(host) when is_binary(host) do
    if ipv6_only?(String.trim(host, "[") |> String.trim("]")),
      do: [tcp_module: :inet6_tcp],
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

  @impl true
  def init({url, owner, headers, timeout_ms}) do
    headers = [{"Sec-WebSocket-Protocol", WebSocketProtocol.subprotocol()} | headers]

    case connect(URI.parse(url), headers, timeout_ms) do
      {:ok, conn, ref, websocket, resp_headers, leftover} ->
        send(owner, {:websocket_upstream_connected, self(), resp_headers})

        state = %{
          conn: conn,
          ref: ref,
          websocket: websocket,
          owner: owner,
          owner_monitor: Process.monitor(owner)
        }

        # The upgrade response can carry the first frames in the same
        # packet; deliver them before reading anything else.
        {:ok, state, {:continue, {:data, leftover}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue({:data, chunks}, state) do
    case handle_data(state, chunks) do
      {:ok, state} -> {:noreply, arm(state)}
      {:stop, reason, state} -> disconnect(state, reason)
    end
  end

  @impl true
  def handle_cast({:send, raw}, state) do
    case send_frame(state, {:text, raw}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> disconnect(state, reason)
    end
  end

  def handle_cast(:close, state) do
    state |> send_frame_quietly({:close, 1000, "session closed"}) |> disconnect(:normal)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    Mint.HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        data = for {:data, ref, chunk} <- responses, ref == state.ref, do: chunk

        case handle_data(%{state | conn: conn}, data) do
          {:ok, state} -> {:noreply, arm(state)}
          {:stop, reason, state} -> disconnect(state, reason)
        end

      {:error, conn, reason, _responses} ->
        disconnect(%{state | conn: conn}, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  # ---- connect ----

  defp connect(%URI{scheme: scheme, host: host} = uri, headers, timeout_ms)
       when scheme in ["ws", "wss"] and is_binary(host) do
    {http_scheme, ws_scheme, transport_opts} =
      if scheme == "wss" do
        {:https, :wss, [timeout: timeout_ms, cacerts: :public_key.cacerts_get()]}
      else
        {:http, :ws, [timeout: timeout_ms] ++ socket_family_options(host)}
      end

    port = uri.port || if(scheme == "wss", do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, host, port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, headers),
         {:ok, conn, status, resp_headers, leftover} <- await_upgrade(conn, ref, deadline),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, resp_headers),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :passive) do
      {:ok, conn, ref, websocket, resp_headers, leftover}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(_uri, _headers, _timeout_ms), do: {:error, :invalid_upstream}

  defp await_upgrade(conn, ref, deadline, acc \\ {nil, [], false, []}) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case Enum.reduce(responses, acc, &collect_upgrade(&1, &2, ref)) do
              {status, headers, true, data} -> {:ok, conn, status, headers, data}
              acc -> await_upgrade(conn, ref, deadline, acc)
            end

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade(conn, ref, deadline, acc)
        end
    after
      remaining -> {:error, conn, :handshake_timeout}
    end
  end

  defp collect_upgrade({:status, ref, status}, {_, headers, done, data}, ref),
    do: {status, headers, done, data}

  defp collect_upgrade({:headers, ref, headers}, {status, _, done, data}, ref),
    do: {status, headers, done, data}

  defp collect_upgrade({:data, ref, chunk}, {status, headers, done, data}, ref),
    do: {status, headers, done, data ++ [chunk]}

  defp collect_upgrade({:done, ref}, {status, headers, _, data}, ref),
    do: {status, headers, true, data}

  defp collect_upgrade(_response, acc, _ref), do: acc

  # ---- reading ----

  # Passive mode plus one `active: :once` per handled chunk: the next chunk
  # is pulled off the socket only after the previous one's frames were
  # recorded by the session.
  defp arm(state) do
    case Mint.HTTP.get_socket(state.conn) do
      socket when is_port(socket) -> :inet.setopts(socket, active: :once)
      socket -> :ssl.setopts(socket, active: :once)
    end

    state
  end

  defp handle_data(state, []), do: {:ok, state}

  defp handle_data(state, chunks) do
    case Mint.WebSocket.decode(state.websocket, IO.iodata_to_binary(chunks)) do
      {:ok, websocket, frames} ->
        handle_frames(%{state | websocket: websocket}, frames)

      {:error, websocket, reason} ->
        send(state.owner, {:websocket_upstream_error, self(), reason})
        {:stop, reason, %{state | websocket: websocket}}
    end
  end

  defp handle_frames(state, []), do: {:ok, state}

  defp handle_frames(state, [{:text, raw} | rest]) do
    if hand_off(state, raw), do: handle_frames(state, rest), else: {:stop, :normal, state}
  end

  defp handle_frames(state, [{:ping, data} | rest]) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> handle_frames(state, rest)
      {:error, state, reason} -> {:stop, reason, state}
    end
  end

  defp handle_frames(state, [{:close, code, reason} | _rest]) do
    {:stop, {:remote, code, reason}, send_frame_quietly(state, {:close, code, ""})}
  end

  defp handle_frames(state, [{:binary, _raw} | _rest]) do
    send(state.owner, {:websocket_upstream_error, self(), :binary_frames_not_supported})
    close = {:close, 1003, "aqueduct.v1 requires JSON text messages"}
    {:stop, :binary_frames_not_supported, send_frame_quietly(state, close)}
  end

  defp handle_frames(state, [_other | rest]), do: handle_frames(state, rest)

  # Returns once the session has recorded the frame; false if the session
  # is gone.
  defp hand_off(state, raw) do
    GenServer.call(state.owner, {:websocket_upstream_frame, self(), raw}, :infinity)
    true
  catch
    :exit, _reason -> false
  end

  # ---- writing / closing ----

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | websocket: websocket, conn: conn}}
          {:error, conn, reason} -> {:error, %{state | websocket: websocket, conn: conn}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  defp send_frame_quietly(state, frame) do
    case send_frame(state, frame) do
      {:ok, state} -> state
      {:error, state, _reason} -> state
    end
  end

  defp disconnect(state, reason) do
    {:ok, conn} = Mint.HTTP.close(state.conn)
    send(state.owner, {:websocket_upstream_disconnected, self(), reason})
    {:stop, :normal, %{state | conn: conn}}
  end
end
