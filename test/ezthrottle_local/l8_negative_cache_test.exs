defmodule EzthrottleLocal.L8NegativeCacheTest do
  @moduledoc """
  A webhook receiver that doesn't speak L8 is probed once, not before every
  delivery. Mirrors Aquifer's TestEnsureTrustRemembersNonL8Receivers.
  """

  use ExUnit.Case, async: false

  defmodule ProbeCounter do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, opts) do
      send(Keyword.fetch!(opts, :test_pid), :probe)
      send_resp(conn, 404, "")
    end

    def call(conn, _opts), do: send_resp(conn, 200, "")
  end

  test "a receiver without L8 metadata is probed once across many webhooks" do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      {Bandit, plug: {ProbeCounter, test_pid: self()}, port: port, startup_log: false}
    )

    url = "http://127.0.0.1:#{port}/hook"
    for _ <- 1..20, do: EzthrottleLocal.L8.ensure_trust(url)

    assert_received :probe
    refute_received :probe
  end
end
