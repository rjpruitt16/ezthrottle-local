defmodule EzthrottleLocal.WebSocketQueueTest do
  use ExUnit.Case, async: true

  alias EzthrottleLocal.{WebSocketConfig, WebSocketQueue}

  defp start_queue(overrides) do
    config =
      struct(
        %{
          WebSocketConfig.load()
          | max_upstreams: 100_000,
            max_waiting: 100_000,
            max_clients: 100_000
        },
        overrides
      )

    name = :"ws_queue_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {WebSocketQueue, :start_link, [config, [name: name]]}})
    name
  end

  defp collect(tag, count, timeout, acc \\ []) do
    if length(acc) >= count do
      Enum.reverse(acc)
    else
      receive do
        {^tag, ref, _value} -> collect(tag, count, timeout, [ref | acc])
      after
        timeout -> Enum.reverse(acc)
      end
    end
  end

  defp count_messages(tag, acc \\ 0) do
    receive do
      {^tag, _ref, _value} -> count_messages(tag, acc + 1)
    after
      0 -> acc
    end
  end

  test "admits at the configured rate, not one per jittered millisecond" do
    queue = start_queue(connect_rps: 2_000.0, slow_start_rps: 2_000.0)
    n = 5_000

    refs =
      for _ <- 1..n do
        {:ok, ref, _position} = WebSocketQueue.enqueue(self(), queue)
        ref
      end

    started = System.monotonic_time(:millisecond)
    admitted = collect(:websocket_admitted, n, 1_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # 5,000 at 2,000/s is 2.5 s. The previous queue granted one per tick of
    # at least 2 ms, so this took 10 s or more.
    assert length(admitted) == n
    assert elapsed < 4_000, "took #{elapsed} ms"
    assert elapsed > 1_500, "faster than the configured rate: #{elapsed} ms"

    # First in, first admitted.
    assert admitted == refs
  end

  test "waiters hear their position about once a second, not on every admission" do
    queue = start_queue(connect_rps: 2_000.0, slow_start_rps: 2_000.0)
    n = 3_000
    for _ <- 1..n, do: {:ok, _ref, _position} = WebSocketQueue.enqueue(self(), queue)

    _admitted = collect(:websocket_admitted, n, 1_000)
    updates = count_messages(:websocket_waiting)

    # One on joining plus at most a few periodic updates each. Renumbering on
    # every admission sent about n²/2 (4.5M here).
    assert updates <= n * 3, "#{updates} position messages"
  end

  test "the default 20/s still paces openings" do
    queue = start_queue(connect_rps: 20.0, slow_start_rps: 20.0)
    for _ <- 1..60, do: {:ok, _ref, _position} = WebSocketQueue.enqueue(self(), queue)

    Process.sleep(1_000)
    admitted = count_messages(:websocket_admitted)
    # 20 in the second, plus the small burst the bucket starts with.
    assert admitted in 18..24, "#{admitted} admitted in 1 s"
  end

  test "a cancelled waiter is skipped and the others move up" do
    queue = start_queue(connect_rps: 1.0, slow_start_rps: 1.0)
    # The first is admitted at once; the next two wait about a second each.
    {:ok, first, 1} = WebSocketQueue.enqueue(self(), queue)
    assert_receive {:websocket_admitted, ^first, _token}, 500
    {:ok, second, 1} = WebSocketQueue.enqueue(self(), queue)
    {:ok, third, 2} = WebSocketQueue.enqueue(self(), queue)

    WebSocketQueue.cancel(second, queue)

    # The next periodic update moves the third waiter to the front.
    assert_receive {:websocket_waiting, ^third, 1}, 2_000
    assert_receive {:websocket_admitted, ^third, _token}, 2_000
    refute_received {:websocket_admitted, ^second, _token}
  end

  test "a failed handshake resets the ramp and pauses openings" do
    queue = start_queue(connect_rps: 1_000.0, slow_start_rps: 1.0)
    for _ <- 1..3, do: WebSocketQueue.report_success(queue)
    assert WebSocketQueue.snapshot(queue).current_ramp_rps == 8.0

    WebSocketQueue.report_failure(queue)
    assert WebSocketQueue.snapshot(queue).current_ramp_rps == 1.0

    {:ok, ref, _position} = WebSocketQueue.enqueue(self(), queue)
    refute_receive {:websocket_admitted, ^ref, _token}, 800
    assert_receive {:websocket_admitted, ^ref, _token}, 1_500
  end
end
