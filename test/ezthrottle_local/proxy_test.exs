defmodule EzthrottleLocal.ProxyTest do
  @moduledoc """
  Mirrors Aquifer's proxy_test.go: proxy mode tries a job directly and
  synchronously first, falling back to the existing durable-queue path
  only on failure, overload, or an already-open circuit breaker.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.Proxy
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.AccountQueueRegistry

  defmodule OkPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "real upstream response")
    end
  end

  defmodule ErrorPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      status = Keyword.get(opts, :status, 500)
      headers = Keyword.get(opts, :headers, [])

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

      send_resp(conn, status, "")
    end
  end

  defmodule CountingErrorPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :hit)

      conn
      |> put_resp_header("retry-after", "60")
      |> send_resp(429, "")
    end
  end

  defmodule SlowPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      Process.sleep(200)
      send_resp(conn, 200, "")
    end
  end

  defp start_server(plug, opts \\ []) do
    port = Enum.random(20_000..60_000)
    child_id = :"proxy_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  defp job_params(user_id, idempotent_key, url) do
    %{
      "user_id" => user_id,
      "idempotent_key" => idempotent_key,
      "url" => url,
      "method" => "POST",
      "webhook_url" => "https://example.com/callback"
    }
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:ezthrottle_local, :proxy_direct_attempt_timeout_ms)
      Application.delete_env(:ezthrottle_local, :proxy_breaker_retry_multiplier)
      Application.delete_env(:ezthrottle_local, :proxy_breaker_default_cooldown_seconds)
    end)

    :ok
  end

  describe "overload?/1" do
    test "200 is not overload" do
      refute Proxy.overload?(%{status: 200, headers: %{}})
    end

    test "429 is overload" do
      assert Proxy.overload?(%{status: 429, headers: %{}})
    end

    test "500 and 503 are overload" do
      assert Proxy.overload?(%{status: 500, headers: %{}})
      assert Proxy.overload?(%{status: 503, headers: %{}})
    end

    test "an ORCA overload header on a 200 is overload" do
      headers = %{"endpoint-load-metrics" => "TEXT named_metrics.kv_cache_usage_perc=0.95"}
      assert Proxy.overload?(%{status: 200, headers: headers})
    end

    test "an ORCA healthy header on a 200 is not overload" do
      headers = %{"endpoint-load-metrics" => "TEXT named_metrics.kv_cache_usage_perc=0.10"}
      refute Proxy.overload?(%{status: 200, headers: headers})
    end
  end

  describe "breaker_cooldown/1" do
    test "uses Retry-After times the configured multiplier" do
      Application.put_env(:ezthrottle_local, :proxy_breaker_retry_multiplier, 2)
      assert Proxy.breaker_cooldown(%{"retry-after" => "3"}) == 6_000
    end

    test "falls back to the configured default without Retry-After" do
      Application.put_env(:ezthrottle_local, :proxy_breaker_default_cooldown_seconds, 9)
      assert Proxy.breaker_cooldown(%{}) == 9_000
    end
  end

  test "a direct success bypasses the queue entirely" do
    url = start_server(OkPlug)
    key = "direct-ok-#{System.unique_integer([:positive])}"

    assert {:direct, job, response} = Proxy.attempt_direct(job_params("user-1", key, url))
    assert response.status == 200
    assert response.body == "real upstream response"
    assert IdempotentStore.get_status(job.id) == "completed"
  end

  test "falls back on 5xx without completing the job" do
    url = start_server(ErrorPlug, status: 500)
    key = "direct-500-#{System.unique_integer([:positive])}"

    assert {:fallback, job} = Proxy.attempt_direct(job_params("user-1", key, url))
    assert IdempotentStore.get_status(job.id) == "queued"
  end

  test "a short timeout triggers a fallback" do
    Application.put_env(:ezthrottle_local, :proxy_direct_attempt_timeout_ms, 20)
    url = start_server(SlowPlug)
    key = "direct-timeout-#{System.unique_integer([:positive])}"

    assert {:fallback, _job} = Proxy.attempt_direct(job_params("user-1", key, url))
  end

  test "429 trips the circuit breaker for that domain" do
    url = start_server(ErrorPlug, status: 429, headers: [{"retry-after", "1"}])
    key = "direct-429-#{System.unique_integer([:positive])}"

    assert {:fallback, job} = Proxy.attempt_direct(job_params("user-1", key, url))
    assert AccountQueueRegistry.breaker_open?(job)
  end

  test "an open breaker skips the direct attempt entirely" do
    url = start_server(CountingErrorPlug, test_pid: self())
    key1 = "breaker-1-#{System.unique_integer([:positive])}"
    key2 = "breaker-2-#{System.unique_integer([:positive])}"

    assert {:fallback, _} = Proxy.attempt_direct(job_params("user-1", key1, url))
    assert_receive :hit, 1_000

    # Second request to the SAME domain (different idempotent key, so it
    # isn't deduped) should skip the direct attempt entirely -- the
    # breaker tripped for 60s x the default multiplier.
    assert {:fallback, _} = Proxy.attempt_direct(job_params("user-1", key2, url))
    refute_receive :hit, 300
  end

  test "a duplicate of a completed job skips a second direct attempt" do
    url = start_server(OkPlug)
    key = "duplicate-#{System.unique_integer([:positive])}"
    params = job_params("user-1", key, url)

    assert {:direct, first_job, _} = Proxy.attempt_direct(params)
    assert {:duplicate, existing} = Proxy.attempt_direct(params)
    assert existing.id == first_job.id
    assert IdempotentStore.get_status(existing.id) == "completed"
  end
end
