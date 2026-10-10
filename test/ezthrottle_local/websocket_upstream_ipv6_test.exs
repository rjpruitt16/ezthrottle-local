defmodule EzthrottleLocal.WebSocketUpstreamIPv6Test do
  use ExUnit.Case, async: true

  alias EzthrottleLocal.WebSocketUpstream

  test "IPv6 literals connect over IPv6" do
    assert WebSocketUpstream.socket_family_options("::1") ==
             [socket_options: [tcp_module: :inet6_tcp]]

    assert WebSocketUpstream.socket_family_options("[fdaa::2]") ==
             [socket_options: [tcp_module: :inet6_tcp]]
  end

  test "IPv4 literals and names with an IPv4 address keep the default" do
    assert WebSocketUpstream.socket_family_options("127.0.0.1") == []
    assert WebSocketUpstream.socket_family_options("localhost") == []
  end

  test "an IPv6-only upstream accepts the connection" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, active: false])

    {:ok, port} = :inet.port(listener)
    opts = Keyword.fetch!(WebSocketUpstream.socket_family_options("::1"), :socket_options)

    {:ok, client} = :gen_tcp.connect(~c"::1", port, [:binary | opts], 1_000)
    {:ok, _server} = :gen_tcp.accept(listener, 1_000)
    :gen_tcp.close(client)
  end
end
