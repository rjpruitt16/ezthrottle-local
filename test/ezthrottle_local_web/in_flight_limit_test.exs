defmodule EzthrottleLocalWeb.InFlightLimitTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EzthrottleLocalWeb.Plugs.InFlightLimit

  setup do
    System.put_env("EZTHROTTLE_MAX_IN_FLIGHT_REQUESTS", "2")
    InFlightLimit.setup()
    on_exit(fn -> System.delete_env("EZTHROTTLE_MAX_IN_FLIGHT_REQUESTS") end)
  end

  # Each request runs in its own process, like a connection handler.
  defp hold_request(path) do
    parent = self()

    spawn(fn ->
      conn = InFlightLimit.call(conn(:post, path), [])
      send(parent, {:admitted, self(), conn.halted, conn.status})

      receive do
        :respond -> send_resp(conn, 201, "") && send(parent, :responded)
      end
    end)

    receive do
      {:admitted, pid, halted, status} -> {pid, halted, status}
    end
  end

  test "sheds past the cap with 429 and frees the slot when a response is sent" do
    {first, false, nil} = hold_request("/jobs")
    {_second, false, nil} = hold_request("/proxy")
    assert InFlightLimit.in_flight() == 2

    {_third, true, 429} = hold_request("/jobs")
    assert InFlightLimit.in_flight() == 2

    send(first, :respond)
    assert_receive :responded
    assert InFlightLimit.in_flight() == 1
    {_fourth, false, nil} = hold_request("/jobs")
  end

  test "the 429 carries Retry-After and the admission error shape" do
    hold_request("/jobs")
    hold_request("/jobs")
    conn = InFlightLimit.call(conn(:post, "/jobs"), [])

    assert conn.status == 429
    assert [_] = get_resp_header(conn, "retry-after")
    assert %{"limit_reason" => "in_flight", "limit" => 2} = Jason.decode!(conn.resp_body)
  end

  test "other routes aren't counted" do
    for _ <- 1..5, do: InFlightLimit.call(conn(:get, "/jobs/abc"), [])
    for _ <- 1..5, do: InFlightLimit.call(conn(:get, "/health"), [])
    assert InFlightLimit.in_flight() == 0
  end

  test "a slot left by a request that died is reclaimed on the connection's next request" do
    # Same process, two requests, the first never responds.
    InFlightLimit.call(conn(:post, "/jobs"), [])
    assert InFlightLimit.in_flight() == 1
    InFlightLimit.call(conn(:post, "/jobs"), [])
    assert InFlightLimit.in_flight() == 1
  end
end
