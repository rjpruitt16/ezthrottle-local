defmodule EzthrottleLocal.DrainFlushTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.{DrainFlush, IdempotentStore, Job}

  # A tiny controllable Plug used as a stand-in webhook receiver -- lets
  # these tests assert exact delivery-attempt counts and force success/
  # failure sequences, which a real external endpoint (the pattern used
  # elsewhere in this test suite, e.g. postman-echo.com) can't provide.
  defmodule TestWebhookPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/.well-known/l8"} = conn, _opts) do
      # deliver/1 calls EzthrottleLocal.L8.ensure_trust/1 first, which
      # probes this path before the real webhook POST -- respond 404 so
      # L8 fails-open (no trust established) without affecting the actual
      # delivery-attempt counting below.
      send_resp(conn, 404, "")
    end

    def call(conn, _opts) do
      counter = Process.whereis(:drain_flush_test_counter)
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      responses = Agent.get(Process.whereis(:drain_flush_test_responses), & &1)
      status = Enum.at(responses, n - 1, List.last(responses))

      {:ok, body, conn} = read_body(conn)
      Agent.update(Process.whereis(:drain_flush_test_bodies), &[body | &1])

      send_resp(conn, status, "")
    end
  end

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end, name: :drain_flush_test_counter)
    {:ok, bodies} = Agent.start_link(fn -> [] end, name: :drain_flush_test_bodies)
    on_exit(fn ->
      if Process.alive?(counter), do: Agent.stop(counter)
      if Process.alive?(bodies), do: Agent.stop(bodies)
    end)
    :ok
  end

  defp start_webhook(responses) do
    {:ok, responses_pid} = Agent.start_link(fn -> responses end, name: :drain_flush_test_responses)
    # A unique port per call, not a fixed one -- a hard-killed listener's
    # socket can take a moment to actually release, and reusing the same
    # port across tests raced that release window (eaddrinuse).
    port = 18_000 + rem(System.unique_integer([:positive]), 5_000)
    {:ok, server} = Bandit.start_link(plug: TestWebhookPlug, port: port, startup_log: false)

    on_exit(fn ->
      if Process.alive?(responses_pid), do: Agent.stop(responses_pid)
      # A hard kill, not Supervisor.stop/1 -- Bandit's supervision tree
      # exits with :shutdown internally regardless of the reason passed to
      # stop/1, which GenServer.stop/3 (what Supervisor.stop/1 calls under
      # the hood) treats as a mismatch and raises on. This is just test
      # cleanup, not something asserting graceful shutdown behavior.
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    "http://localhost:#{port}"
  end

  defp seed_ledger_entry do
    stamp = System.unique_integer([:positive])

    job = %Job{
      id: "drain-#{stamp}",
      user_id: "drain-user",
      idempotent_key: "drain-key-#{stamp}",
      url: "https://example.com/webhook",
      method: "POST",
      headers: %{},
      body: nil,
      webhook_url: "https://example.com/callback",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }

    :ok = IdempotentStore.check_or_insert(job)
    job
  end

  test "attempt/0 succeeds on first delivery and clears the ledger" do
    url = start_webhook([200])
    System.put_env("EZTHROTTLE_DRAIN_WEBHOOK_URL", url)
    on_exit(fn -> System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL") end)

    IdempotentStore.clear_ledger()
    seed_ledger_entry()

    assert DrainFlush.attempt() == true
    assert Agent.get(:drain_flush_test_counter, & &1) == 1
    assert IdempotentStore.list_ledger() == []

    [body] = Agent.get(:drain_flush_test_bodies, & &1)
    payload = Jason.decode!(body)
    assert payload["event"] == "instance_idle"
    assert is_list(payload["ledger"])
    assert length(payload["ledger"]) == 1
  end

  test "attempt/0 with an empty ledger skips delivery entirely" do
    url = start_webhook([200])
    System.put_env("EZTHROTTLE_DRAIN_WEBHOOK_URL", url)
    on_exit(fn -> System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL") end)

    IdempotentStore.clear_ledger()

    assert DrainFlush.attempt() == true
    assert Agent.get(:drain_flush_test_counter, & &1) == 0
  end

  @tag timeout: 60_000
  test "attempt/0 does not clear the ledger when delivery exhausts all retries" do
    url = start_webhook([500])
    System.put_env("EZTHROTTLE_DRAIN_WEBHOOK_URL", url)
    on_exit(fn -> System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL") end)

    IdempotentStore.clear_ledger()
    seed_ledger_entry()

    assert DrainFlush.attempt() == false
    assert IdempotentStore.list_ledger() |> length() == 1

    # Retrying (mirroring the watchdog's next tick) must be safe and must
    # still find the ledger intact -- nothing was cleared on failure.
    assert DrainFlush.attempt() == false
    assert IdempotentStore.list_ledger() |> length() == 1
  end

  @tag timeout: 30_000
  test "attempt/0 clears the ledger on success within the retry budget, not just first-attempt success" do
    url = start_webhook([500, 500, 200])
    System.put_env("EZTHROTTLE_DRAIN_WEBHOOK_URL", url)
    on_exit(fn -> System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL") end)

    IdempotentStore.clear_ledger()
    seed_ledger_entry()

    assert DrainFlush.attempt() == true
    assert Agent.get(:drain_flush_test_counter, & &1) == 3
    assert IdempotentStore.list_ledger() == []
  end

  test "enabled?/0 treats enabled-but-no-webhook-url as disabled" do
    System.put_env("EZTHROTTLE_DRAIN_ENABLED", "true")
    System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL")

    on_exit(fn ->
      System.delete_env("EZTHROTTLE_DRAIN_ENABLED")
      System.delete_env("EZTHROTTLE_DRAIN_WEBHOOK_URL")
    end)

    refute DrainFlush.enabled?()
  end

  test "enabled?/0 is false by default" do
    System.delete_env("EZTHROTTLE_DRAIN_ENABLED")
    refute DrainFlush.enabled?()
  end
end
