defmodule EzthrottleLocalWeb.JobController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.AccountQueueRegistry

  @doc """
  POST /jobs
  Submit a job for queuing and execution.
  """
  def create(conn, params) do
    case Job.new(params) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:ok, job} ->
        case IdempotentStore.check_or_insert(job.idempotent_key, job.id) do
          {:duplicate, existing_id} ->
            conn
            |> put_status(:ok)
            |> json(%{
              job_id: existing_id,
              status: "queued",
              duplicate: true
            })

          :ok ->
            AccountQueueRegistry.enqueue(job)

            conn
            |> put_status(:created)
            |> json(%{
              job_id: job.id,
              status: "queued"
            })
        end
    end
  end

  @doc """
  GET /jobs/:id
  Get the status of a job.
  """
  def show(conn, %{"id" => job_id}) do
    case IdempotentStore.get_status(job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job not found"})

      status ->
        json(conn, %{
          job_id: job_id,
          status: status
        })
    end
  end
end
