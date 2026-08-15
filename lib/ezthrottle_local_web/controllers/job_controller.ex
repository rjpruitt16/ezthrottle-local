defmodule EzthrottleLocalWeb.JobController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Metrics
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Admission

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
