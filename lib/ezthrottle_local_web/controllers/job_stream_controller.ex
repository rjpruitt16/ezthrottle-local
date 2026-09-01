defmodule EzthrottleLocalWeb.JobStreamController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.AccountQueueRegistry

  def stream(conn, %{"id" => job_id}) do
    case IdempotentStore.get_job(job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job not found"})

      job ->
        stream_events(conn, job)
    end
  end

  @doc """
  Subscribes to this job's events and streams them via SSE on the given
  connection -- stream/2's actual behavior, extracted so proxy mode's
  fallback path (JobController.proxy/2) can reuse it verbatim
  ("automatically start streaming") instead of reimplementing it.

  proxy_fallback is nil for a plain GET /jobs/:id/stream -- this job never
  had a direct attempt to explain. When set (proxy mode's fallback path
  only, `%{reason: string, status: integer | nil}`), one extra event is
  written first: a client watching the stream (a browser, an agent with no
  server of its own to learn this any other way) sees explicitly why it's
  in the queue instead of just "queued" with no context. Mirrors Aquifer's
  streamEvents/ProxyFallbackInfo.
  """
  def stream_events(conn, job, proxy_fallback \\ nil) do
    IdempotentStore.set_delivery_mode(job.id, :stream)
    Phoenix.PubSub.subscribe(EzthrottleLocal.PubSub, "job:#{job.id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    conn =
      case proxy_fallback do
        nil ->
          conn

        %{reason: reason, status: status} ->
          data = %{job_id: job.id, reason: reason}
          data = if status, do: Map.put(data, :upstream_status, status), else: data
          {:ok, conn} = chunk(conn, sse_event("proxy_fallback", data))
          conn
      end

    # Send catchup events for any states already passed before client connected
    status = IdempotentStore.get_status(job.id)
    conn = send_catchup_events(conn, job.id, status)

    listen_loop(conn, job)
  end

  # Send synthetic events for states the client missed by connecting late
  defp send_catchup_events(conn, job_id, status) do
    {:ok, conn} = chunk(conn, sse_event("queued", %{job_id: job_id, status: "queued"}))

    case status do
      s when s in ["in_flight", "completed", "failed"] ->
        {:ok, conn} = chunk(conn, sse_event("dispatching", %{job_id: job_id}))
        conn

      _ ->
        conn
    end
  end

  defp listen_loop(conn, job) do
    receive do
      {:job_event, %{event: event} = data} ->
        case chunk(conn, sse_event(event, data)) do
          {:ok, conn} ->
            case event do
              e when e in ["completed", "failed"] -> conn
              _ -> listen_loop(conn, job)
            end

          {:error, :closed} ->
            handle_disconnect(job, event, data)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> listen_loop(conn, job)
          {:error, :closed} -> IdempotentStore.set_delivery_mode(job.id, :stream_fallback)
        end
    end
  end

  # Stream died on the final event — queue the webhook with normalized
  # payload through the same paced account-queue delivery AccountQueue
  # itself uses, rather than firing it synchronously on this connection's
  # own process.
  defp handle_disconnect(job, "completed", data) do
    AccountQueueRegistry.enqueue_webhook(job.id, job.user_id, job.webhook_url, %{
      job_id: job.id,
      status: "completed",
      response_status: data[:response_status],
      body: data[:body]
    })
  end

  defp handle_disconnect(job, "failed", data) do
    AccountQueueRegistry.enqueue_webhook(job.id, job.user_id, job.webhook_url, %{
      job_id: job.id,
      status: "failed",
      reason: data[:reason]
    })
  end

  # Stream died mid-job — AccountQueue fires webhook on completion
  defp handle_disconnect(job, _event, _data) do
    IdempotentStore.set_delivery_mode(job.id, :stream_fallback)
  end

  defp sse_event(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end

  @doc """
  Forwards a redirected region's own SSE response byte-for-byte onto the
  original caller's connection in real time -- a pure relay, not a
  re-parse/re-emit, since preserving the target's own event framing exactly
  is both simpler and more faithful than reconstructing it. Used only when
  EzthrottleLocal.Redirect found a sibling region that accepted the job
  into its own durable queue; the caller sees one continuous stream
  regardless of which region actually ends up handling the job. Mirrors
  Aquifer's relaySSE.

  region is announced via a synthetic "rerouted" event before the relay
  starts -- same rationale as proxy_fallback: a client with no server of
  its own to explain this (a browser, an agent) should know why its
  connection is still open and where the response is actually coming from,
  not just start seeing target's own queued/dispatching events with no
  context.
  """
  def relay_stream(conn, request_id, region) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    case chunk(conn, sse_event("rerouted", %{region: region})) do
      {:ok, conn} ->
        relay_loop(conn, request_id)

      {:error, :closed} ->
        :httpc.cancel_request(request_id)
        conn
    end
  end

  defp relay_loop(conn, request_id) do
    receive do
      {:http, {^request_id, :stream, part}} ->
        case chunk(conn, part) do
          {:ok, conn} ->
            relay_loop(conn, request_id)

          {:error, :closed} ->
            :httpc.cancel_request(request_id)
            conn
        end

      {:http, {^request_id, :stream_end, _final_headers}} ->
        conn

      {:http, {^request_id, {:error, _reason}}} ->
        conn
    after
      60_000 ->
        :httpc.cancel_request(request_id)
        conn
    end
  end
end
