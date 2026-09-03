defmodule EzthrottleLocal.SlowStartTest do
  @moduledoc """
  Mirrors Aquifer's account_queue_test.go / registry_test.go slow-start
  coverage: a queue started with slow_start: true begins at @min_rps
  regardless of its configured ceiling (a fresh queue's first dispatch has
  no prior response to read a pacing signal from, so the starting point has
  to be decided up front), the existing creep-back-up-toward-configured_rps
  behavior is what actually ramps it from there, and an upstream's
  X-Aqueduct-Slow-Start response header persists at the UrlActor level to
  apply to the *next* new queue on that domain, not retroactively.
  """

  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Job

  @min_rps 0.5

  defp job_for(user_id, api_key, url) do
    stamp = System.unique_integer([:positive])

    %Job{
      id: "ss-#{stamp}",
      user_id: user_id,
      idempotent_key: "ss-key-#{stamp}",
      url: url,
      method: "POST",
      headers: %{"Authorization" => api_key},
      body: nil,
      webhook_url: nil,
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  defp url_actor_state_for(url) do
    uri = URI.parse(url)
    port_suffix = if uri.port, do: ":#{uri.port}", else: ""
    url_key = "#{uri.scheme}://#{uri.host}#{port_suffix}"
    [{^url_key, pid}] = :ets.lookup(:url_actors, url_key)
    :sys.get_state(pid)
  end

  test "slow_start: true begins at @min_rps regardless of the configured ceiling" do
    {:ok, pid} =
      AccountQueue.start_link(
        queue_key: :shared,
        upstream: "https://example.com",
        rps: 100.0,
        max_concurrent: 5,
        slow_start: true
      )

    assert :sys.get_state(pid).rps == @min_rps
  end

  test "slow_start off by default begins at the configured rps" do
    {:ok, pid} =
      AccountQueue.start_link(
        queue_key: :shared,
        upstream: "https://example.com",
        rps: 12.0,
        max_concurrent: 5
      )

    assert :sys.get_state(pid).rps == 12.0
  end

  defmodule SlowStartPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("x-aqueduct-slow-start", "true")
      |> send_resp(200, "")
    end
  end

  defp start_plug_server(plug) do
    port = Enum.random(20_000..60_000)
    child_id = :"slow_start_test_#{port}"

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, []}, port: port}, id: child_id)
    )

    "http://127.0.0.1:#{port}"
  end

  test "the header applies to the next new queue on that domain, not the one that saw it" do
    base_url = start_plug_server(SlowStartPlug)
    url = "#{base_url}/dispatch"

    first = job_for("tenant-first", "key-first", url)
    :ok = AccountQueueRegistry.enqueue(first, "enabled")

    # Wait for the first job's response (carrying the header) to flip the
    # domain's UrlActor over to slow_start_enabled.
    assert wait_until(fn -> url_actor_state_for(url).slow_start_enabled end),
           "expected UrlActor.slow_start_enabled to become true after a response carrying X-Aqueduct-Slow-Start: true"

    second = job_for("tenant-second", "key-second", url)
    :ok = AccountQueueRegistry.enqueue(second, "enabled")

    second_key = Job.queue_key(second)

    queue_pid =
      wait_until_value(fn -> Map.get(url_actor_state_for(url).queues, second_key) end)

    assert :sys.get_state(queue_pid).rps == @min_rps
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, deadline)
    end
  end

  defp wait_until_value(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(10)
          wait_until_value(fun, deadline)
        end

      value ->
        value
    end
  end
end
