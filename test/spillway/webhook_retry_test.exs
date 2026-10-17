# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.WebhookRetryTest do
  @moduledoc """
  Mirrors Aquifer's webhook_retry_test.go: webhook_max_retries sets the retry
  limit for a job's webhook delivery, and a failed response can't raise the
  queue's pace even when it advertises a rate.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Spillway.{AccountQueueRegistry, IdempotentStore, Job}
  alias SpillwayWeb.JobController

  # A webhook receiver that answers 503 while `down?.(attempt)` is true, then
  # 200. Reports {:hook_attempt, n} for every attempt and
  # {:delivered, job_id} for every accepted delivery. With `advertise`, every
  # response carries X-Aqueduct-Rps, 503s included.
  defmodule FlakyReceiver do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")

    def call(conn, %{counter: counter, down?: down?, test_pid: test_pid} = opts) do
      n = :atomics.add_get(counter, 1, 1)
      send(test_pid, {:hook_attempt, n})

      conn =
        if opts[:advertise], do: put_resp_header(conn, "x-aqueduct-rps", "100000"), else: conn

      if down?.(n) do
        send_resp(conn, 503, "down")
      else
        {:ok, body, conn} = read_body(conn)

        case Jason.decode(body) do
          {:ok, %{"job_id" => id}} -> send(test_pid, {:delivered, id})
          _ -> :ok
        end

        send_resp(conn, 200, "ok")
      end
    end
  end

  defmodule OkPlug do
    import Plug.Conn
    def init(opts), do: opts
    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")
    def call(conn, _opts), do: send_resp(conn, 200, ~s({"ok":true}))
  end

  defmodule FailingPlug do
    import Plug.Conn
    def init(opts), do: opts
    def call(%{request_path: "/.well-known/l8"} = conn, _opts), do: send_resp(conn, 404, "")

    def call(conn, test_pid) do
      send(test_pid, :upstream_attempt)
      send_resp(conn, 502, "bad gateway")
    end
  end

  setup do
    Spillway.L8.forget_not_trusted()

    previous =
      for key <- [:default_rps, :dispatch_retry_ms],
          do: {key, Application.get_env(:spillway, key)}

    Application.put_env(:spillway, :default_rps, 100.0)
    Application.put_env(:spillway, :dispatch_retry_ms, 0)

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:spillway, key),
          else: Application.put_env(:spillway, key, value)
      end
    end)

    :ok
  end

  defp start_server(plug, opts) do
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {plug, opts}, port: port}, id: :"hook_retry_#{port}")
    )

    "http://127.0.0.1:#{port}"
  end

  defp receiver(down?, extra \\ %{}) do
    opts = Map.merge(%{counter: :atomics.new(1, []), down?: down?, test_pid: self()}, extra)
    start_server(FlakyReceiver, opts)
  end

  defp submit(url, webhook, extra) do
    {:ok, job} =
      %{
        "user_id" => "hook-retry-user",
        "idempotent_key" => "hook-retry-#{System.unique_integer([:positive])}",
        "url" => url,
        "method" => "POST",
        "webhook_url" => webhook
      }
      |> Map.merge(extra)
      |> Job.new()

    :ok = IdempotentStore.check_or_insert(job)
    AccountQueueRegistry.enqueue(job, "")
    job
  end

  defp last_attempt(acc \\ 0) do
    receive do
      {:hook_attempt, n} -> last_attempt(max(acc, n))
    after
      0 -> acc
    end
  end

  defp collect_delivered(ids, want, deadline) do
    if MapSet.size(ids) >= want do
      ids
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:delivered, id} -> collect_delivered(MapSet.put(ids, id), want, deadline)
      after
        remaining -> ids
      end
    end
  end

  # Four retries used to be the default, which gave a webhook about 15 seconds
  # of backoff before it was dropped (spillway#67).
  test "webhook delivery defaults to ten retries" do
    hook = receiver(fn _ -> true end)
    submit(start_server(OkPlug, nil) <> "/x", hook, %{})

    assert_receive {:hook_attempt, 11}, 15_000
    refute_receive {:hook_attempt, 12}, 500
  end

  test "an explicit webhook_max_retries still caps delivery" do
    hook = receiver(fn _ -> true end)
    submit(start_server(OkPlug, nil) <> "/x", hook, %{"webhook_max_retries" => 4})

    assert_receive {:hook_attempt, 5}, 10_000
    refute_receive {:hook_attempt, 6}, 500
  end

  test "webhook_max_retries -1 keeps retrying until the receiver accepts it" do
    hook = receiver(fn n -> n <= 12 end)
    job = submit(start_server(OkPlug, nil) <> "/x", hook, %{"webhook_max_retries" => -1})

    assert_receive {:delivered, id}, 15_000
    assert id == job.id
    assert last_attempt(13) == 13
  end

  test "webhook_max_retries leaves the upstream's retries alone" do
    hook = receiver(fn n -> n <= 6 end)

    submit(start_server(FailingPlug, self()) <> "/x", hook, %{
      "max_retries" => 0,
      "webhook_max_retries" => 10
    })

    assert_receive {:delivered, _}, 15_000
    assert_received :upstream_attempt
    refute_received :upstream_attempt
  end

  # The soak's receiver stamps X-Aqueduct-Rps on every response, 503s
  # included. That advertised rate used to replace the halved pace, so the
  # queue kept full speed against a down receiver and webhooks used up their
  # default retries within seconds of an outage starting.
  test "a failed response can't raise the pace, so a short outage loses no webhooks" do
    Application.put_env(:spillway, :dispatch_retry_ms, 100)
    jobs = 30
    start = System.monotonic_time(:millisecond)
    down? = fn _ -> System.monotonic_time(:millisecond) - start < 1_500 end
    hook = receiver(down?, %{advertise: true})
    upstream = start_server(OkPlug, nil) <> "/x"

    for _ <- 1..jobs, do: submit(upstream, hook, %{})

    delivered =
      collect_delivered(MapSet.new(), jobs, System.monotonic_time(:millisecond) + 30_000)

    assert MapSet.size(delivered) == jobs,
           "only #{MapSet.size(delivered)} of #{jobs} webhooks delivered (#{last_attempt()} attempts)"
  end

  test "validates webhook_max_retries and lets the header override the body" do
    base = %{
      "user_id" => "u",
      "idempotent_key" => "k",
      "url" => "http://x",
      "method" => "GET",
      "webhook_url" => "http://w"
    }

    for good <- [-1, 0, 4, 100, "-1"] do
      assert {:ok, _} = Job.new(Map.put(base, "webhook_max_retries", good))
    end

    for bad <- [-2, 101, "forever"] do
      assert {:error, msg} = Job.new(Map.put(base, "webhook_max_retries", bad))
      assert msg =~ "webhook_max_retries"
    end

    params =
      Map.merge(base, %{
        "idempotent_key" => "hook-hdr-#{System.unique_integer([:positive])}",
        "webhook_max_retries" => 0
      })

    conn =
      build_conn(:post, "/jobs", params)
      |> Plug.Conn.put_req_header("x-aqueduct-webhook-max-retries", "-1")
      |> JobController.create(params)

    assert conn.status == 201
    stored = IdempotentStore.get_job(Jason.decode!(conn.resp_body)["job_id"])
    assert stored.webhook_max_retries == -1
    assert stored.max_retries == 4

    conn =
      build_conn(:post, "/jobs", base)
      |> Plug.Conn.put_req_header("x-aqueduct-webhook-max-retries", "nope")
      |> JobController.create(base)

    assert conn.status == 400
  end

  test "an unset or pre-upgrade webhook_max_retries means the default" do
    {:ok, job} =
      Job.new(%{
        "user_id" => "u",
        "idempotent_key" => "k",
        "url" => "http://x",
        "method" => "GET",
        "webhook_url" => "http://w"
      })

    assert job.webhook_max_retries == nil
    assert Job.webhook_max_retries(job) == 10

    # A job stored before this field existed has no :webhook_max_retries key.
    old = Map.delete(job, :webhook_max_retries)
    assert Job.webhook_max_retries(Job.upgrade(old)) == 10
  end
end
