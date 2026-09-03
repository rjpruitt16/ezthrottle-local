defmodule EzthrottleLocal.RegistrationTest do
  @moduledoc """
  Mirrors Aquifer's registration_test.go.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.Registration

  setup do
    on_exit(fn ->
      System.delete_env("EZTHROTTLE_REGISTRY_URL")
      System.delete_env("PORT")
      System.delete_env("EZTHROTTLE_REGISTRY_INTERVAL_SECONDS")
    end)
  end

  test "disabled by default with no EZTHROTTLE_REGISTRY_URL set" do
    System.delete_env("EZTHROTTLE_REGISTRY_URL")
    refute Registration.enabled?()
  end

  test "port defaults to 4000, matching the same PORT convention application.ex already uses" do
    System.delete_env("PORT")
    assert Registration.port() == "4000"
  end

  defmodule RegistrationPingPlug do
    import Plug.Conn

    def init(opts), do: opts

    # L8.ensure_trust/1 (called by Webhook.deliver/2 before the real POST)
    # does its own preliminary GET /.well-known/l8 handshake probe first --
    # not the payload this test cares about. Same guard Aquifer's own
    # tests use (skipL8Probe in registry_test.go) for the identical
    # request Aquifer's L8Registry makes.
    def call(%{request_path: "/.well-known/l8"} = conn, _opts) do
      send_resp(conn, 404, "")
    end

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      send(Keyword.fetch!(opts, :test_pid), {:ping_received, decoded["port"]})
      send_resp(conn, 200, "")
    end
  end

  test "pings immediately and again on the next interval, reporting the real listening port" do
    test_pid = self()

    port = Enum.random(20_000..60_000)
    child_id = :"registration_test_#{port}"

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: {RegistrationPingPlug, test_pid: test_pid}, port: port},
        id: child_id
      )
    )

    System.put_env("EZTHROTTLE_REGISTRY_URL", "http://127.0.0.1:#{port}")
    System.put_env("PORT", "9999")
    System.put_env("EZTHROTTLE_REGISTRY_INTERVAL_SECONDS", "1")

    assert Registration.enabled?()

    start_supervised!(Registration)

    assert_receive {:ping_received, "9999"}, 2_000
    assert_receive {:ping_received, "9999"}, 3_000
  end
end
