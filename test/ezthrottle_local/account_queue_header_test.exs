defmodule EzthrottleLocal.AccountQueueHeaderTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Job

  # Regression test for the gap Aquifer's own AccountQueue fix closed
  # earlier: account-queue isolation could previously only be toggled by
  # the upstream's response header or static config — there was no way
  # for the client submitting a job to request isolation directly. These
  # assert on AccountQueueRegistry.enqueue/2's new second argument end to
  # end, inspecting UrlActor's real internal queue state via :sys.get_state
  # rather than just checking the call doesn't crash.

  defp job_for(user_id, api_key, host) do
    stamp = System.unique_integer([:positive])

    %Job{
      id: "aq-#{stamp}",
      user_id: user_id,
      idempotent_key: "aq-key-#{stamp}",
      # UrlActors are keyed by scheme+host only (query strings don't
      # create separate actors), so the two tests below need genuinely
      # different hosts to get independent UrlActor state — both are
      # real, fast, reliable echo services, chosen for the same reason
      # Aquifer's own tests avoid slow/failing dummy URLs: a background
      # dispatch/retry goroutine left alive past the test function
      # returning is exactly what caused flakiness there.
      url: "https://#{host}/post",
      method: "POST",
      headers: %{"Authorization" => api_key},
      body: nil,
      webhook_url: "https://#{host}/post",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  defp url_actor_state_for(job) do
    uri = URI.parse(job.url)
    port_suffix = if uri.port, do: ":#{uri.port}", else: ""
    url_key = "#{uri.scheme}://#{uri.host}#{port_suffix}"
    [{^url_key, pid}] = :ets.lookup(:url_actors, url_key)
    :sys.get_state(pid)
  end

  test "X-Aqueduct-Account-Queue: enabled isolates tenants into distinct queues" do
    noisy = job_for("tenant-noisy", "key-noisy", "postman-echo.com")
    quiet = job_for("tenant-quiet", "key-quiet", "postman-echo.com")

    :ok = AccountQueueRegistry.enqueue(noisy, "enabled")
    :ok = AccountQueueRegistry.enqueue(quiet, "enabled")

    state = url_actor_state_for(noisy)

    assert state.account_queue_enabled

    noisy_key = Job.queue_key(noisy)
    quiet_key = Job.queue_key(quiet)

    assert noisy_key != quiet_key, "test setup bug: expected distinct tenant keys"
    assert Map.has_key?(state.queues, noisy_key)
    assert Map.has_key?(state.queues, quiet_key)
    refute Map.has_key?(state.queues, :shared)
  end

  test "omitting the header keeps the shared-queue default behavior" do
    a = job_for("tenant-a", "key-a", "httpbin.org")
    b = job_for("tenant-b", "key-b", "httpbin.org")

    :ok = AccountQueueRegistry.enqueue(a)
    :ok = AccountQueueRegistry.enqueue(b)

    state = url_actor_state_for(a)

    refute state.account_queue_enabled
    assert Map.has_key?(state.queues, :shared)
  end
end
