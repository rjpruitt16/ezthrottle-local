defmodule EzthrottleLocalWeb.JobStreamController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Webhook

  def stream(conn, %{"id" => job_id}) do
    case IdempotentStore.get_job(job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job not found"})

      job ->
        IdempotentStore.set_delivery_mode(job_id, :stream)
        Phoenix.PubSub.subscribe(EzthrottleLocal.PubSub, "job:#{job_id}")

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Send catchup events for any states already passed before client connected
        status = IdempotentStore.get_status(job_id)
        conn = send_catchup_events(conn, job_id, status)

        listen_loop(conn, job)
    end
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

  # Stream died on the final event — fire webhook with normalized payload
  defp handle_disconnect(job, "completed", data) do
    Webhook.deliver(job.webhook_url, %{
      job_id: job.id,
      status: "completed",
      response_status: data[:response_status],
      body: data[:body]
    })
  end

  defp handle_disconnect(job, "failed", data) do
    Webhook.deliver(job.webhook_url, %{
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
end
