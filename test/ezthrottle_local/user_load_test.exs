defmodule EzthrottleLocal.UserLoadTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias EzthrottleLocal.{Job, UserLoad}
  alias EzthrottleLocalWeb.JobController

  defmodule StuckPlug do
    import Plug.Conn
    def init(opts), do: opts
    def call(%{request_path: "/.well-known/l8"} = conn, _), do: send_resp(conn, 404, "")

    def call(conn, :hang) do
      receive do
      after
        10_000 -> send_resp(conn, 200, "late")
      end
    end

    def call(%{request_path: "/slow"} = conn, :upstream), do: call(conn, :hang)
    def call(conn, :upstream), do: send_resp(conn, 200, ~s({"ok":true}))
  end

  setup do
    UserLoad.reset()
    on_exit(fn -> System.delete_env("EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER") end)
    :ok
  end

  defp webhook_job(user), do: %Job{id: "w", user_id: user, webhook_url: ""}
  defp user_job(user), do: %Job{id: "j", user_id: user, webhook_url: "https://example.com/hook"}

  test "decision: lone user never rejected; probability scales from W to 2W; 0 disables" do
    # Unique users: another test's late webhook completions for busy would
    # otherwise shift these counts.
    stamp = System.unique_integer([:positive])
    busy = "busy-#{stamp}"
    neighbor = "neighbor-#{stamp}"
    System.put_env("EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER", "1000")
    for _ <- 1..1500, do: UserLoad.add(webhook_job(busy))

    assert UserLoad.webhook_backlog_decision(busy, 0.0) == :ok

    UserLoad.add(user_job(neighbor))
    assert UserLoad.webhook_backlog_decision(busy, 0.4) == {:rejected, 1000, 1500}
    assert UserLoad.webhook_backlog_decision(busy, 0.6) == :ok
    assert UserLoad.webhook_backlog_decision(neighbor, 0.0) == :ok

    for _ <- 1..600, do: UserLoad.done(webhook_job(busy))
    assert UserLoad.webhook_backlog_decision(busy, 0.0) == :ok

    System.put_env("EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER", "0")
    for _ <- 1..5000, do: UserLoad.add(webhook_job(busy))
    assert UserLoad.webhook_backlog_decision(busy, 0.0) == :ok
  end

  test "counts never go negative" do
    UserLoad.done(webhook_job("ghost"))
    assert UserLoad.webhooks("ghost") == 0
  end

  test "a shared instance 429s the user whose webhooks are backing up" do
    # "Shared" means other users have work here; leftovers from earlier tests
    # would count, so start from an idle node.
    EzthrottleLocal.NodeIdle.wait()
    UserLoad.reset()
    System.put_env("EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER", "1")
    hook = start_server(:hang)
    upstream = start_server(:upstream)

    submit = fn user, key, path ->
      params = %{
        "user_id" => user,
        "idempotent_key" => "#{key}-#{System.unique_integer([:positive])}",
        "url" => upstream <> path,
        "method" => "POST",
        "webhook_url" => hook
      }

      JobController.create(build_conn(:post, "/jobs", params), params)
    end

    for key <- ["b1", "b2", "b3"], do: assert(submit.("busy", key, "/ok").status == 201)
    assert wait_for(fn -> UserLoad.webhooks("busy") >= 2 end)
    assert submit.("busy", "b4", "/ok").status == 201

    assert submit.("neighbor", "n1", "/slow").status == 201
    rejected = submit.("busy", "b5", "/ok")
    assert rejected.status == 429
    assert Jason.decode!(rejected.resp_body)["limit_reason"] == "webhook_backlog"
  end

  defp start_server(mode) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {StuckPlug, mode}, port: port},
        id: :"user_load_#{port}"
      )
    )

    "http://127.0.0.1:#{port}"
  end

  defp wait_for(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      ok = fun.()
      unless ok, do: Process.sleep(20)
      ok
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end
end
