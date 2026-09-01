defmodule EzthrottleLocal.RedirectTest do
  @moduledoc """
  Mirrors Aquifer's region_redirect_test.go: pure-logic coverage
  (rendezvous_pick/2, ordered_redirect_candidates/4, the gate,
  self_machine_id/0) plus real dual-instance integration tests -- target is
  a real Bandit-hosted plug, origin is driven via Phoenix.ConnTest with
  :region_adapter and the redirect-target-URL builder overridden to point
  at it, the same way Aquifer's buildRedirectTestPair works with a second
  real httptest.Server.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias EzthrottleLocal.Redirect
  alias EzthrottleLocalWeb.JobController

  defmodule FakeRegionAdapter do
    @behaviour EzthrottleLocal.RegionAdapter
    def live_regions, do: ["target-region"]
    def self_region, do: "origin-region"
  end

  describe "rendezvous_pick/2" do
    test "deterministic regardless of input order" do
      candidates = ["iad", "lhr", "sjc", "nrt"]
      first = Redirect.rendezvous_pick(candidates, "some-idempotent-key")

      reordered = ["nrt", "sjc", "lhr", "iad"]
      second = Redirect.rendezvous_pick(reordered, "some-idempotent-key")

      assert first == second
      assert first == Redirect.rendezvous_pick(candidates, "some-idempotent-key")
    end

    test "empty candidates returns nil" do
      assert Redirect.rendezvous_pick([], "key") == nil
    end
  end

  describe "ordered_redirect_candidates/4" do
    test "excludes self and already-visited regions" do
      live = ["iad", "lhr", "sjc", "nrt"]
      visited = ["sjc"]

      candidates = Redirect.ordered_redirect_candidates(live, visited, "iad", "some-key")

      refute "iad" in candidates
      refute "sjc" in candidates
      assert length(candidates) == 2
    end

    test "rendezvous-preferred region is always first" do
      live = ["iad", "lhr", "sjc", "nrt", "fra"]
      preferred = Redirect.rendezvous_pick(live, "some-key")

      [first | _] = Redirect.ordered_redirect_candidates(live, [], "", "some-key")

      assert first == preferred
    end

    test "empty when the only live region is self" do
      assert Redirect.ordered_redirect_candidates(["iad"], [], "iad", "key") == []
    end
  end

  describe "gate" do
    test "opens on trip, closes after cooldown" do
      start_supervised!(Redirect.gate_child_spec())

      refute Redirect.gate_open?()

      Redirect.gate_trip(50)
      assert Redirect.gate_open?()

      Process.sleep(60)
      refute Redirect.gate_open?()
    end
  end

  describe "self_machine_id/0" do
    test "stable across repeat calls" do
      first = Redirect.self_machine_id()
      second = Redirect.self_machine_id()
      assert first == second
      assert is_binary(first)
    end
  end

  # -- Real dual-instance integration tests --

  defp start_server(plug) do
    port = Enum.random(20_000..60_000)
    child_id = :"redirect_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, []}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  defp configure_origin(target_url) do
    old_adapter = Application.get_env(:ezthrottle_local, :region_adapter)
    old_builder = Application.get_env(:ezthrottle_local, :redirect_target_url_builder)

    Application.put_env(:ezthrottle_local, :region_adapter, FakeRegionAdapter)
    Application.put_env(:ezthrottle_local, :redirect_target_url_builder, fn "target-region" -> target_url end)

    on_exit(fn ->
      if old_adapter,
        do: Application.put_env(:ezthrottle_local, :region_adapter, old_adapter),
        else: Application.delete_env(:ezthrottle_local, :region_adapter)

      if old_builder,
        do: Application.put_env(:ezthrottle_local, :redirect_target_url_builder, old_builder),
        else: Application.delete_env(:ezthrottle_local, :redirect_target_url_builder)
    end)
  end

  defmodule DirectSuccessPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("x-served-by", "target-region")
      |> send_resp(200, ~s({"ok":true}))
    end
  end

  test "direct success via redirect relays target's response and tags the served-by region" do
    target_url = start_server(DirectSuccessPlug)
    configure_origin(target_url)

    key = "redirect-direct-#{System.unique_integer([:positive])}"

    params = %{
      "user_id" => "user-1",
      "idempotent_key" => key,
      "url" => "http://127.0.0.1:1/unreachable",
      "method" => "GET",
      "webhook_url" => "https://example.com/callback"
    }

    conn = build_conn(:post, "/proxy", params)
    conn = JobController.proxy(conn, params)

    assert conn.status == 200
    assert conn.resp_body == ~s({"ok":true})
    assert get_resp_header(conn, "x-served-by") == ["target-region"]
    assert get_resp_header(conn, "x-aquifer-served-by-region") == ["target-region"]

    # Origin's own job row must be gone -- the real job now lives on the
    # target region under its own ID. Without this cleanup, the row sits
    # at status :queued forever, and a later retry of the same
    # idempotent_key would find it via check_or_insert, open a stream, and
    # hang forever waiting on a PubSub topic nothing will ever broadcast
    # to again. check_or_insert on the identical user_id/idempotent_key
    # returning :ok (not :duplicate) proves the row is actually gone.
    {:ok, retry_job} = EzthrottleLocal.Job.new(params)
    assert EzthrottleLocal.IdempotentStore.check_or_insert(retry_job) == :ok
    EzthrottleLocal.IdempotentStore.delete_job(retry_job)
  end

  defmodule QueueStreamPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      params = Jason.decode!(body)

      if params["direct_only"] do
        send_resp(conn, 503, "")
      else
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        {:ok, conn} =
          chunk(conn, "event: proxy_fallback\ndata: #{Jason.encode!(%{job_id: "target-job-1", reason: "domain_degraded"})}\n\n")

        {:ok, conn} = chunk(conn, "event: queued\ndata: #{Jason.encode!(%{job_id: "target-job-1", status: "queued"})}\n\n")
        conn
      end
    end
  end

  test "queue-commit via redirect relays target's stream with a rerouted event announced first" do
    target_url = start_server(QueueStreamPlug)
    configure_origin(target_url)

    key = "redirect-queue-#{System.unique_integer([:positive])}"

    params = %{
      "user_id" => "user-1",
      "idempotent_key" => key,
      "url" => "http://127.0.0.1:1/unreachable",
      "method" => "GET",
      "webhook_url" => "https://example.com/callback"
    }

    conn = build_conn(:post, "/proxy", params)
    conn = JobController.proxy(conn, params)

    body = conn.resp_body

    reroute_idx = :binary.match(body, "event: rerouted") |> elem(0)
    fallback_idx = :binary.match(body, "event: proxy_fallback") |> elem(0)

    assert String.contains?(body, ~s("region":"target-region"))
    assert String.contains?(body, "event: proxy_fallback")
    assert String.contains?(body, "event: queued")
    assert reroute_idx < fallback_idx

    # Same cleanup requirement as the direct-success case: the real job now
    # lives on the target region under its own ID, so origin's own row must
    # be gone too, not just in the direct-success path.
    {:ok, retry_job} = EzthrottleLocal.Job.new(params)
    assert EzthrottleLocal.IdempotentStore.check_or_insert(retry_job) == :ok
    EzthrottleLocal.IdempotentStore.delete_job(retry_job)
  end

  defmodule AlreadyRedirectedPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 503, "")
    end
  end

  test "does not originate a further redirect for a request that already carries origin_machine_id" do
    target_url = start_server(AlreadyRedirectedPlug)
    configure_origin(target_url)

    upstream_url = start_server(AlreadyRedirectedPlug)
    key = "redirect-already-#{System.unique_integer([:positive])}"

    params = %{
      "user_id" => "user-1",
      "idempotent_key" => key,
      "url" => upstream_url,
      "method" => "GET",
      "webhook_url" => "https://example.com/callback",
      "origin_machine_id" => "some-other-machine",
      "origin_region" => "some-other-region"
    }

    conn = build_conn(:post, "/proxy", params)
    conn = JobController.proxy(conn, params)

    assert get_resp_header(conn, "content-type") |> hd() |> String.starts_with?("text/event-stream")
    body = conn.resp_body
    assert String.contains?(body, ~s("reason":"upstream_overloaded")) or
             String.contains?(body, ~s("reason":"domain_degraded")) or
             String.contains?(body, ~s("reason":"upstream_unreachable"))

    refute String.contains?(body, "event: rerouted")
  end

  defmodule UnreachablePlug do
  end

  test "total exhaustion returns a hard 429, not a silent local queue" do
    # Point the redirect target at a genuinely unreachable address --
    # nothing listens there, so every hop fails to even reach the target.
    old_adapter = Application.get_env(:ezthrottle_local, :region_adapter)
    old_builder = Application.get_env(:ezthrottle_local, :redirect_target_url_builder)

    Application.put_env(:ezthrottle_local, :region_adapter, FakeRegionAdapter)

    Application.put_env(:ezthrottle_local, :redirect_target_url_builder, fn "target-region" ->
      "http://127.0.0.1:1/proxy"
    end)

    System.put_env("EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS", "123")

    on_exit(fn ->
      if old_adapter,
        do: Application.put_env(:ezthrottle_local, :region_adapter, old_adapter),
        else: Application.delete_env(:ezthrottle_local, :region_adapter)

      if old_builder,
        do: Application.put_env(:ezthrottle_local, :redirect_target_url_builder, old_builder),
        else: Application.delete_env(:ezthrottle_local, :redirect_target_url_builder)

      System.delete_env("EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS")
    end)

    upstream_url = start_server(AlreadyRedirectedPlug)
    key = "redirect-exhausted-#{System.unique_integer([:positive])}"

    params = %{
      "user_id" => "user-1",
      "idempotent_key" => key,
      "url" => upstream_url,
      "method" => "GET",
      "webhook_url" => "https://example.com/callback"
    }

    conn = build_conn(:post, "/proxy", params)
    conn = JobController.proxy(conn, params)

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["123"]
    assert conn.resp_body =~ ~s("limit_reason":"redirect_exhausted")
  end
end
