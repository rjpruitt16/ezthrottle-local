defmodule EzthrottleLocal.WebSocketUpstream do
  @moduledoc """
  One WebSocket connection to a session's backend.

  The socket is read one chunk at a time. Its frames are handed to the
  session one at a time, each acknowledged once the session has recorded
  it, and only when the chunk's last frame is acknowledged is the socket
  armed for the next chunk. While the session is behind nothing more is
  read, the kernel buffers fill, and TCP slows the backend down.

  Writes go through a separate linked writer process, each command
  confirmed to the session once written so it can bound how many are
  outstanding. A blocking write must not stall this process: a backend
  that stops reading because its own sends to us are blocked would
  otherwise wait on us while we wait on it, and neither side would read
  again. WebSockex, used before, kept its socket in
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

  # Remembered per host for a few minutes: answering it takes two DNS
  # lookups, which on top of the connect's own lookup cost each new session
  # three, and in the Fly lab the lookups alone added ~30% to connect times
  # during a 500/s burst.
  @family_cache_ms 300_000

  defp ipv6_only?(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        tuple_size(address) == 8

      {:error, _} ->
        key = {__MODULE__, :ipv6_only, host}
        now = System.monotonic_time(:millisecond)

        case :persistent_term.get(key, nil) do
          {answer, expires} when expires > now ->
            answer

          _ ->
            answer =
              not match?({:ok, _}, :inet.getaddr(charlist, :inet)) and
                match?({:ok, _}, :inet.getaddr(charlist, :inet6))

            :persistent_term.put(key, {answer, now + @family_cache_ms})
            answer
        end
    end
  end

  @impl true
  def init({url, owner, headers, timeout_ms}) do
    headers = [{"Sec-WebSocket-Protocol", WebSocketProtocol.subprotocol()} | headers]

    case connect(URI.parse(url), headers, timeout_ms) do
      {:ok, conn, ref, websocket, resp_headers, leftover} ->
        send(owner, {:websocket_upstream_connected, self(), resp_headers})

        upstream = self()
        socket = Mint.HTTP.get_socket(conn)
        writer = spawn_link(fn -> write_loop(socket, owner, upstream) end)

        state = %{
          conn: conn,
          ref: ref,
          websocket: websocket,
          writer: writer,
          owner: owner,
          owner_monitor: Process.monitor(owner),
          frames: [],
          awaiting: nil
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
    state |> handle_data(chunks) |> continue()
  end

  @impl true
  def handle_cast({:send, raw}, state) do
    case send_frame(state, {:text, raw}, true) do
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

  def handle_info({:websocket_upstream_write_failed, reason}, state),
    do: disconnect(state, reason)

  def handle_info({:websocket_upstream_frame_recorded, ref}, %{awaiting: ref} = state) do
    %{state | awaiting: nil} |> next_frame() |> continue()
  end

  def handle_info({:websocket_upstream_frame_recorded, _ref}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        data = for {:data, ref, chunk} <- responses, ref == state.ref, do: chunk
        %{state | conn: conn} |> handle_data(data) |> continue()

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
         # Mint.WebSocket re-arms the socket itself in its default :active
         # mode, which would read the backend as fast as it sends.
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(conn, ref, status, resp_headers, mode: :passive),
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

  defp continue({:ok, state}), do: {:noreply, state}
  defp continue({:stop, reason, state}), do: disconnect(state, reason)

  # Passive mode plus one `active: :once` once a chunk's frames have all
  # been recorded: the next chunk is pulled off the socket only then.
  defp arm(state) do
    case Mint.HTTP.get_socket(state.conn) do
      socket when is_port(socket) -> :inet.setopts(socket, active: :once)
      socket -> :ssl.setopts(socket, active: :once)
    end

    state
  end

  defp handle_data(state, []), do: next_frame(state)

  defp handle_data(state, chunks) do
    case Mint.WebSocket.decode(state.websocket, IO.iodata_to_binary(chunks)) do
      {:ok, websocket, frames} ->
        next_frame(%{state | websocket: websocket, frames: state.frames ++ frames})

      {:error, websocket, reason} ->
        send(state.owner, {:websocket_upstream_error, self(), reason})
        {:stop, reason, %{state | websocket: websocket}}
    end
  end

  # One text frame with the session at a time; the socket is armed again
  # only when none is outstanding and none is left from the chunk.
  defp next_frame(%{awaiting: ref} = state) when ref != nil, do: {:ok, state}
  defp next_frame(%{frames: []} = state), do: {:ok, arm(state)}

  defp next_frame(%{frames: [frame | rest]} = state) do
    state = %{state | frames: rest}

    case frame do
      {:text, raw} ->
        ref = make_ref()
        send(state.owner, {:websocket_upstream_frame, self(), ref, raw})
        {:ok, %{state | awaiting: ref}}

      {:ping, data} ->
        case send_frame(state, {:pong, data}) do
          {:ok, state} -> next_frame(state)
          {:error, state, reason} -> {:stop, reason, state}
        end

      {:close, code, reason} ->
        {:stop, {:remote, code, reason}, send_frame_quietly(state, {:close, code, ""})}

      {:binary, _raw} ->
        send(state.owner, {:websocket_upstream_error, self(), :binary_frames_not_supported})
        close = {:close, 1003, "aqueduct.v1 requires JSON text messages"}
        {:stop, :binary_frames_not_supported, send_frame_quietly(state, close)}

      _other ->
        next_frame(state)
    end
  end

  # ---- writing / closing ----

  # Encoding stays here (it carries the WebSocket state); the bytes go to
  # the writer, in order. confirm? marks commands the session counts.
  defp send_frame(state, frame, confirm? \\ false) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        send(state.writer, {:write, data, confirm?})
        {:ok, %{state | websocket: websocket}}

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  defp write_loop(socket, owner, upstream) do
    receive do
      {:write, data, confirm?} ->
        result =
          if is_port(socket), do: :gen_tcp.send(socket, data), else: :ssl.send(socket, data)

        case result do
          :ok ->
            if confirm?, do: send(owner, {:websocket_upstream_written, upstream})
            write_loop(socket, owner, upstream)

          {:error, reason} ->
            send(upstream, {:websocket_upstream_write_failed, reason})
        end
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
