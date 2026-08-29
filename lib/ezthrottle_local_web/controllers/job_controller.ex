defmodule EzthrottleLocalWeb.JobController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Metrics
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Admission
  alias EzthrottleLocal.Proxy
  alias EzthrottleLocalWeb.JobStreamController

  def create(conn, params) do
    case Job.new(params) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:ok, job} ->
        case IdempotentStore.check_or_insert(job) do
          {:duplicate, existing_id} ->
            # Idempotency check comes first: a retried job that already
            # exists must still succeed even while the system is over an
            # admission limit.
            conn
            |> put_status(:ok)
            |> json(%{job_id: existing_id, status: "queued", duplicate: true})

          :ok ->
            # check_or_insert already wrote this job's rows since it
            # wasn't a duplicate. If admission rejects it now, those rows
            # must be deleted or they become a ghost "queued" entry that
            # never dispatches.
            case Admission.check() do
              :ok ->
                Metrics.job_queued(job.user_id, Metrics.upstream(job.url))
                AccountQueueRegistry.enqueue(job, account_queue_header(conn))

                conn
                |> put_status(:created)
                |> json(%{job_id: job.id, status: "queued"})

              {:rejected, reason, limit, current} ->
                IdempotentStore.delete_job(job)
                retry_after = Admission.retry_after_seconds()

                conn
                |> put_resp_header("retry-after", to_string(retry_after))
                |> put_status(429)
                |> json(%{
                  error: "admission rejected: #{reason} at #{current} exceeds limit #{limit}",
                  limit_reason: reason,
                  limit: limit,
                  current: current
                })
            end
        end
    end
  end

  @doc """
  Proxy mode: try the upstream directly and synchronously first; fall back
  to the same durable-queue-and-SSE path create/2 + stream/2 always use,
  on this same connection, only on failure/overload/an already-open
  circuit breaker. See EzthrottleLocal.Proxy for the actual decision
  logic -- this action is HTTP glue only.
  """
  def proxy(conn, params) do
    case Proxy.attempt_direct(params) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:admission_rejected, reason, limit, current} ->
        retry_after = Admission.retry_after_seconds()

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(429)
        |> json(%{
          error: "admission rejected: #{reason} at #{current} exceeds limit #{limit}",
          limit_reason: reason,
          limit: limit,
          current: current
        })

      {:duplicate, existing_job} ->
        stream_or_status_for_duplicate(conn, existing_job)

      {:direct, _job, response} ->
        conn = Enum.reduce(response.headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        send_resp(conn, response.status, response.body)

      {:fallback, job, reason} ->
        AccountQueueRegistry.enqueue(job, account_queue_header(conn))
        JobStreamController.stream_events(conn, job, reason)
    end
  end

  # A duplicate of an already-terminal job has no cached response body to
  # replay (Job never persists it past the transient SSE/webhook payload)
  # -- opening a stream for it would just keepalive forever, since its
  # completed/failed event already fired before this request ever
  # subscribed. Return its current status synchronously instead; only a
  # still-in-flight duplicate gets a real stream. existing_job's own
  # :status field is frozen at construction time (always :queued) --
  # IdempotentStore.get_status/1 is the actual current status.
  defp stream_or_status_for_duplicate(conn, job) do
    case IdempotentStore.get_status(job.id) do
      status when status in ["completed", "failed"] ->
        json(conn, %{job_id: job.id, status: status, duplicate: true})

      _ ->
        JobStreamController.stream_events(conn, job)
    end
  end

  def show(conn, %{"id" => job_id}) do
    case IdempotentStore.get_job(job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job not found"})

      job ->
        status = IdempotentStore.get_status(job_id)

        json(conn, %{
          job_id: job_id,
          status: status,
          url: job.url,
          pool_id: job.pool_id,
          method: job.method,
          created_at: job.created_at
        })
    end
  end

  # Reads X-Aqueduct-Account-Queue first, falling back to
  # X-EZThrottle-Account-Queue — this is the client-facing request-header
  # path for opting a job into per-tenant isolation directly. It previously
  # didn't exist at all: account-queue mode could only be toggled by the
  # *upstream's response* headers or static config, with no way for the
  # client submitting the job to ask for isolation up front.
  defp account_queue_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-aqueduct-account-queue") do
      [val | _] ->
        val

      [] ->
        case Plug.Conn.get_req_header(conn, "x-ezthrottle-account-queue") do
          [val | _] -> val
          [] -> nil
        end
    end
  end
end
