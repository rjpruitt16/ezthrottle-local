defmodule EzthrottleLocalWeb.JobController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.AccountQueueRegistry

  def create(conn, params) do
    case Job.new(params) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:ok, job} ->
        case IdempotentStore.check_or_insert(job) do
          {:duplicate, existing_id} ->
            conn
            |> put_status(:ok)
            |> json(%{job_id: existing_id, status: "queued", duplicate: true})

          :ok ->
            AccountQueueRegistry.enqueue(job)

            conn
            |> put_status(:created)
            |> json(%{job_id: job.id, status: "queued"})
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
          method: job.method,
          created_at: job.created_at
        })
    end
  end
end
