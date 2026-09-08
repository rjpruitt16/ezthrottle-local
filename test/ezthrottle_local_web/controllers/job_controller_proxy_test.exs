defmodule EzthrottleLocalWeb.JobControllerProxyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias EzthrottleLocalWeb.JobController
  alias EzthrottleLocal.IdempotentStore

  defmodule OkPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("x-upstream", "yes")
      |> send_resp(200, ~s({"ok":true}))
    end
  end

  defp start_server(plug) do
    port = Enum.random(20_000..60_000)
    child_id = :"job_controller_proxy_test_#{port}"

    start_supervised!(Supervisor.child_spec({Bandit, plug: {plug, []}, port: port}, id: child_id))

    "http://127.0.0.1:#{port}"
  end

  test "POST /proxy relays a real upstream response verbatim when it succeeds directly" do
    IdempotentStore.clear_ledger()
    url = start_server(OkPlug)
    key = "http-direct-#{System.unique_integer([:positive])}"

    params = %{
      "user_id" => "user-1",
      "idempotent_key" => key,
      "url" => url,
      "method" => "POST",
      "webhook_url" => "https://example.com/callback"
    }

    conn = build_conn(:post, "/proxy", params)
    conn = JobController.proxy(conn, params)

    assert conn.status == 200
    assert conn.resp_body == ~s({"ok":true})
    assert get_resp_header(conn, "x-upstream") == ["yes"]

    job_id =
      IdempotentStore.list_ledger()
      |> Enum.find(&(&1.status == :completed))
      |> Map.fetch!(:job_id)

    show_conn = build_conn(:get, "/jobs/#{job_id}")
    show_conn = JobController.show(show_conn, %{"id" => job_id})
    polled = Jason.decode!(show_conn.resp_body)

    assert polled["status"] == "completed"

    assert polled["result"] == %{
             "job_id" => job_id,
             "status" => "completed",
             "response_status" => 200,
             "body" => ~s({"ok":true})
           }

    duplicate_conn = build_conn(:post, "/proxy", params)
    duplicate_conn = JobController.proxy(duplicate_conn, params)
    duplicate = Jason.decode!(duplicate_conn.resp_body)

    assert duplicate_conn.status == 200
    assert duplicate["duplicate"] == true
    assert duplicate["job_id"] == job_id
    assert duplicate["result"] == polled["result"]
  end
end
