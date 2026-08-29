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

  defmodule QueueActiveHeaderPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("x-aqueduct-queue-active", "true")
      |> send_resp(200, "still a real answer")
    end
  end

  # First hit trips the breaker (429); every hit after that blocks until
  # released, reporting its own pid to test_pid so the test can unblock it
  # once it's done asserting -- used to simulate a fallback job that's
  # genuinely still in flight after the breaker's own cooldown has elapsed.
  defmodule TripThenBlockPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      counter = Keyword.fetch!(opts, :counter)
      test_pid = Keyword.fetch!(opts, :test_pid)
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      if n == 1 do
        send_resp(conn, 429, "")
      else
        send(test_pid, {:blocked, self()})

        receive do
          :release -> :ok
        end

        send_resp(conn, 200, "")
      end
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

    assert {:fallback, job, %{reason: "upstream_overloaded", status: 500}} =
             Proxy.attempt_direct(job_params("user-1", key, url))

    assert IdempotentStore.get_status(job.id) == "queued"
  end

  test "a short timeout triggers a fallback" do
    Application.put_env(:ezthrottle_local, :proxy_direct_attempt_timeout_ms, 20)
    url = start_server(SlowPlug)
    key = "direct-timeout-#{System.unique_integer([:positive])}"

    assert {:fallback, _job, %{reason: "upstream_unreachable", status: nil}} =
             Proxy.attempt_direct(job_params("user-1", key, url))
  end

  test "429 trips the circuit breaker for that domain" do
    url = start_server(ErrorPlug, status: 429, headers: [{"retry-after", "1"}])
    key = "direct-429-#{System.unique_integer([:positive])}"

    assert {:fallback, job, %{reason: "upstream_overloaded", status: 429}} =
             Proxy.attempt_direct(job_params("user-1", key, url))

    assert AccountQueueRegistry.breaker_open?(job)
  end

  test "an open breaker skips the direct attempt entirely" do
    url = start_server(CountingErrorPlug, test_pid: self())
    key1 = "breaker-1-#{System.unique_integer([:positive])}"
    key2 = "breaker-2-#{System.unique_integer([:positive])}"

    assert {:fallback, _, %{reason: "upstream_overloaded", status: 429}} =
             Proxy.attempt_direct(job_params("user-1", key1, url))

    assert_receive :hit, 1_000

    # Second request to the SAME domain (different idempotent key, so it
    # isn't deduped) should skip the direct attempt entirely -- the
    # breaker tripped for 60s x the default multiplier.
    assert {:fallback, _, %{reason: "domain_degraded", status: nil}} =
             Proxy.attempt_direct(job_params("user-1", key2, url))

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

  test "X-Aqueduct-Queue-Active: true still relays the response but trips the breaker" do
    url = start_server(QueueActiveHeaderPlug)
    key = "queue-active-#{System.unique_integer([:positive])}"

    assert {:direct, job, response} = Proxy.attempt_direct(job_params("user-1", key, url))
    assert response.status == 200
    assert response.body == "still a real answer"
    assert AccountQueueRegistry.breaker_open?(job)
  end

  test "falls back while the queue still has backlog, even after the breaker cooldown elapses" do
    Application.put_env(:ezthrottle_local, :proxy_breaker_default_cooldown_seconds, 1)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()
    url = start_server(TripThenBlockPlug, counter: counter, test_pid: test_pid)
    key_a = "backlog-a-#{System.unique_integer([:positive])}"
    key_b = "backlog-b-#{System.unique_integer([:positive])}"

    assert {:fallback, job, %{reason: "upstream_overloaded", status: 429}} =
             Proxy.attempt_direct(job_params("user-1", key_a, url))

    # Simulate what the real controller does on fallback (job_controller.ex
    # proxy/2): actually enqueue the job, so the domain's queue has real
    # backlog, not just a persisted-but-untouched job record.
    AccountQueueRegistry.enqueue(job, nil)

    assert wait_until(fn -> AccountQueueRegistry.queue_active?(job) end, 2_000),
           "expected the dispatched fallback job to show up as queue backlog"

    blocked_pid =
      receive do
        {:blocked, pid} -> pid
      after
        2_000 -> flunk("expected the fallback job's own request to reach the upstream")
      end

    Process.sleep(1_100)
    refute AccountQueueRegistry.breaker_open?(job), "test setup: expected the cooldown to have elapsed"

    # The breaker itself is closed now, but the domain still has a real
    # backlog draining (the blocked in-flight request from the first
    # fallback) -- a third request should still fall back, not attempt
    # direct, since the cooldown expiring doesn't mean the backlog it
    # caused has actually finished.
    assert {:fallback, _, %{reason: "domain_degraded", status: nil}} =
             Proxy.attempt_direct(job_params("user-1", key_b, url))

    assert Agent.get(counter, & &1) == 2

    send(blocked_pid, :release)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> (Process.sleep(10); do_wait_until(fun, deadline))
    end
  end
end
