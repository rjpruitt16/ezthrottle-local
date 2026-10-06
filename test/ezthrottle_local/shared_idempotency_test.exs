defmodule EzthrottleLocal.SharedIdempotencyTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias EzthrottleLocal.Job
  alias EzthrottleLocalWeb.JobController

  defmodule OkPlug do
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, ~s({"ok":true}))
  end

  setup do
    System.put_env("EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED", "true")
    on_exit(fn -> System.delete_env("EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED") end)
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {OkPlug, []}, port: port}, id: :"shared_idem_#{port}")
    )

    {:ok, url: "http://127.0.0.1:#{port}/resource"}
  end

  defp params(user_id, key, url, scope) do
    %{
      "user_id" => user_id,
      "idempotent_key" => key,
      "idempotency_scope" => scope,
      "url" => url,
      "method" => "GET",
      "webhook_url" => "https://example.com/callback"
    }
  end

  defp create(params) do
    conn = JobController.create(build_conn(:post, "/jobs", params), params)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "shared scope coalesces different users onto one job", %{url: url} do
    key = "weather:sf:#{System.unique_integer([:positive])}"

    {201, first} = create(params("agent-a", key, url, "shared"))
    {200, second} = create(params("agent-b", key, url, "shared"))

    assert second["duplicate"] == true
    assert second["job_id"] == first["job_id"]
  end

  test "user scope stays independent across users", %{url: url} do
    key = "weather:sf:#{System.unique_integer([:positive])}"

    {201, _} = create(params("agent-a", key, url, "shared"))
    {201, a} = create(params("agent-a", key, url, nil))
    {201, b} = create(params("agent-b", key, url, "user"))

    assert a["job_id"] != b["job_id"]
  end

  test "shared scope requires the flag", %{url: url} do
    System.delete_env("EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED")

    assert {:error, msg} = Job.new(params("agent-a", "k", url, "shared"))
    assert msg =~ "EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED"
  end

  test "rejects unknown scopes and NUL user_ids", %{url: url} do
    assert {:error, msg} = Job.new(params("agent-a", "k", url, "global"))
    assert msg =~ "idempotency_scope"

    assert {:error, msg} = Job.new(params("shared" <> <<0>> <> "x", "k", url, nil))
    assert msg =~ "NUL"
  end
end
