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

        status = IdempotentStore.get_status(job_id)
        {:ok, conn} = chunk(conn, sse_event("queued", %{job_id: job_id, status: status}))

        listen_loop(conn, job)
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

  defp handle_disconnect(job, event, data) when event in ["completed", "failed"] do
    Webhook.deliver(job.webhook_url, Map.put(data, :job_id, job.id))
  end

  defp handle_disconnect(job, _event, _data) do
    IdempotentStore.set_delivery_mode(job.id, :stream_fallback)
  end

  defp sse_event(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end
end
