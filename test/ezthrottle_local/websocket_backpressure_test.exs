defmodule EzthrottleLocal.WebSocketBackpressureTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.{
    WebSocketConfig,
    WebSocketSession,
    WebSocketSessionSupervisor,
    WebSocketUpstream
  }

  # A backend that sends `count` events as fast as its socket accepts them,
  # counting how many it got onto the wire.
  defmodule FloodBackend do
    @behaviour WebSock

    @impl true
    def init(opts) do
      send(self(), :flood)
      {:ok, Map.put(opts, :next, 1)}
    end

    @impl true
    def handle_in({raw, opcode: :text}, state) do
      :counters.add(state.received, 1, 1)
      if state.echo, do: {:push, {:text, raw}, state}, else: {:ok, state}
    end

    @impl true
    def handle_info(:flood, %{next: next, count: count} = state) when next > count,
      do: {:ok, state}

    def handle_info(:flood, state) do
      last = min(state.next + 99, state.count)

      frames =
        for n <- state.next..last do
          {:text,
           Jason.encode!(%{
             "type" => "event",
             "message_id" => "m#{n}",
             "payload" => %{"n" => n, "pad" => state.pad}
           })}
        end

      # Bandit writes the pushed frames before the next message; once the
      # client stops reading, that write blocks and the counter stops.
      :counters.put(state.sent, 1, last)
      send(self(), :flood)
      {:push, frames, %{state | next: last + 1}}
    end

    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule BackendPlug do
    def init(opts), do: opts

    def call(conn, opts) do
      conn
      |> Plug.Conn.put_resp_header("sec-websocket-protocol", "aqueduct.v1")
      |> WebSockAdapter.upgrade(FloodBackend, opts, timeout: :infinity)
      |> Plug.Conn.halt()
    end
  end

  defp start_backend(count, pad_bytes, echo \\ true) do
    port = Enum.random(20_000..60_000)
    sent = :counters.new(1, [])
    received = :counters.new(1, [])

    opts = %{
      count: count,
      pad: String.duplicate("x", pad_bytes),
      sent: sent,
      received: received,
      echo: echo
    }

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {BackendPlug, opts}, port: port},
        id: :"ws_backend_#{port}"
      )
    )

    Process.put(:backend_received, received)
    {"ws://127.0.0.1:#{port}/ws", sent}
  end

  defp next_frame(timeout \\ 5_000) do
    receive do
      {:websocket_upstream_frame, pid, ref, raw} -> {{pid, ref}, raw}
    after
      timeout -> flunk("no frame handed off within #{timeout}ms")
    end
  end

  defp recorded({pid, ref}), do: send(pid, {:websocket_upstream_frame_recorded, ref})

  test "the upstream reads no further while the session is still recording a frame" do
    total = 20_000
    {url, sent} = start_backend(total, 1_000)

    {:ok, upstream} = WebSocketUpstream.start(url, self(), [], 5_000)
    assert_receive {:websocket_upstream_connected, ^upstream, _headers}, 5_000

    # Hold the first frame, as a session stuck on a slow store would.
    {held, first} = next_frame()
    Process.sleep(1_000)

    # Nothing queued behind it: the session's mailbox has no further frames,
    # the upstream holds at most the chunk it was decoding, and the backend
    # is blocked on its socket well short of the 20 MB it wants to send.
    assert Process.info(self(), :message_queue_len) == {:message_queue_len, 0}
    assert {:message_queue_len, upstream_queue} = Process.info(upstream, :message_queue_len)
    assert upstream_queue <= 1
    assert length(:sys.get_state(upstream).frames) < total
    assert :counters.get(sent, 1) < total

    # Once the session catches up, every frame arrives, in order.
    recorded(held)

    rest =
      for _ <- 2..total do
        {frame, raw} = next_frame()
        recorded(frame)
        raw
      end

    ns = Enum.map([first | rest], &Jason.decode!(&1)["payload"]["n"])
    assert ns == Enum.to_list(1..total)
    WebSocketUpstream.close(upstream)
  end

  test "commands reach the backend while a frame waits to be recorded" do
    {url, _sent} = start_backend(10, 10, false)
    received = Process.get(:backend_received)

    {:ok, upstream} = WebSocketUpstream.start(url, self(), [], 5_000)
    assert_receive {:websocket_upstream_connected, ^upstream, _headers}, 5_000

    # The lab found commands queueing in the upstream's mailbox behind
    # frames the session hadn't recorded yet.
    {_held, _raw} = next_frame()

    for n <- 1..5 do
      WebSocketUpstream.send_message(upstream, %{"type" => "command", "message_id" => "c#{n}"})
    end

    for _ <- 1..5, do: assert_receive({:websocket_upstream_written, ^upstream}, 5_000)
    wait_until(fn -> :counters.get(received, 1) == 5 end)
    WebSocketUpstream.close(upstream)
  end

  test "the upstream stops when its session goes away" do
    {url, _sent} = start_backend(0, 0)
    owner = self()

    session =
      spawn(fn ->
        {:ok, upstream} = WebSocketUpstream.start(url, self(), [], 5_000)
        send(owner, {:upstream, upstream})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:upstream, upstream}, 5_000
    ref = Process.monitor(upstream)
    send(session, :stop)
    assert_receive {:DOWN, ^ref, :process, ^upstream, :normal}, 5_000
  end

  test "a session holds command replies once the backend is behind by its buffer" do
    session_id = "backend-buffer-#{System.unique_integer([:positive])}"
    config = %{WebSocketConfig.load() | backend_buffer: 3}

    # Nothing listens here: the upstream never connects, so recorded
    # commands wait in the session.
    {:ok, session} =
      WebSocketSessionSupervisor.get_or_start(
        session_id: session_id,
        upstream_url: "ws://127.0.0.1:1/ws",
        upstream_headers: [],
        config: config
      )

    {:ok, _replayed} = WebSocketSession.attach(session, self(), "0-0")

    for n <- 1..3 do
      assert {:ok, %{"type" => "command_recorded"}} =
               WebSocketSession.command(session, self(), %{
                 "type" => "command",
                 "message_id" => "c#{n}"
               })
    end

    client = self()

    fourth =
      Task.async(fn ->
        WebSocketSession.command(session, client, %{"type" => "command", "message_id" => "c4"})
      end)

    assert Task.yield(fourth, 300) == nil
    Task.shutdown(fourth, :brutal_kill)
  end

  test "a client that stops reading holds at most its buffer; it catches up from the store" do
    total = 200
    buffer = 8
    {url, _sent} = start_backend(total, 10)
    session_id = "backpressure-#{System.unique_integer([:positive])}"
    config = %{WebSocketConfig.load() | client_buffer: buffer, read_batch: 16}

    {:ok, session} =
      WebSocketSessionSupervisor.get_or_start(
        session_id: session_id,
        upstream_url: url,
        upstream_headers: [],
        config: config
      )

    {:ok, _replayed} = WebSocketSession.attach(session, self(), "0-0")

    # The backend sends all 200 events; the client acknowledges none.
    wait_until(fn -> stored_events(session_id) >= total end)
    held = drain_events()
    assert length(held) == buffer

    # Acknowledge as the frames are written: the rest arrives, in order,
    # with nothing skipped or repeated.
    Enum.each(held, fn _ -> WebSocketSession.delivered(session, self()) end)
    received = receive_all(session, held, total)
    ns = Enum.map(received, & &1["payload"]["n"])
    assert ns == Enum.to_list(1..total)

    stream_ids = Enum.map(received, & &1["stream_id"])
    assert stream_ids == Enum.uniq(stream_ids)
  end

  defp receive_all(_session, received, total) when length(received) >= total, do: received

  defp receive_all(session, received, total) do
    receive do
      {:websocket_event, message} ->
        WebSocketSession.delivered(session, self())
        receive_all(session, received ++ [message], total)
    after
      5_000 -> flunk("stalled at #{length(received)} of #{total} events")
    end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:websocket_event, message} -> drain_events(acc ++ [message])
    after
      200 -> acc
    end
  end

  defp stored_events(session_id) do
    case EzthrottleLocal.WebSocketStore.read_after(session_id, "0-0", 1_000) do
      {:ok, events} -> Enum.count(events, &(&1.direction == "backend"))
      _ -> 0
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end
end
