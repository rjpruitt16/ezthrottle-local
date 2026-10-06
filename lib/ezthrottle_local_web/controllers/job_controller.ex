defmodule EzthrottleLocalWeb.JobController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Admission
  alias EzthrottleLocal.Proxy
  alias EzthrottleLocal.Redirect
  alias EzthrottleLocalWeb.JobStreamController

  def create(conn, params) do
    case Job.new(with_max_retries_header(conn, params)) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:ok, job} ->
        case validate_schema(job) do
          :ok -> submit(conn, job)
          {:error, mismatch} -> schema_mismatch(conn, mismatch)
        end
    end
  end

  defp submit(conn, job) do
    case AccountQueueRegistry.submit(job, account_queue_header(conn)) do
      {:duplicate, existing_id} ->
        conn
        |> put_status(:ok)
        |> json(duplicate_response(existing_id))

      {:accepted, accepted_job} ->
        conn
        |> put_queue_headers(accepted_job)
        |> put_status(:created)
        |> json(%{job_id: accepted_job.id, status: "queued"})

      {:rejected, reason, limit, current} ->
        conn
        |> put_queue_headers(job)
        |> admission_rejected(reason, limit, current)
    end
  end

  # Pool-routed jobs have no caller-supplied URL to check.
  defp validate_schema(%Job{url: url} = job) when is_binary(url),
    do: EzthrottleLocal.L8.Schemas.validate(url, job.method, job.body)

  defp validate_schema(_job), do: :ok

  defp schema_mismatch(conn, %{route: route, schema_hash: hash, detail: detail}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "request body does not match the schema the upstream advertises for #{route}",
      schema_route: route,
      schema_hash: hash,
      schema_errors: detail
    })
  end

  @doc """
  Proxy mode: try the upstream directly and synchronously first; fall back
  to the same durable-queue-and-SSE path create/2 + stream/2 always use,
  on this same connection, only on failure/overload/an already-open
  circuit breaker. See EzthrottleLocal.Proxy for the actual decision
  logic -- this action is HTTP glue only.
  """
  def proxy(conn, params) do
    case Proxy.attempt_direct(with_max_retries_header(conn, params), account_queue_header(conn)) do
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:admission_rejected, reason, limit, current} ->
        admission_rejected(conn, reason, limit, current)

      {:schema_mismatch, mismatch} ->
        schema_mismatch(conn, mismatch)

      {:duplicate, existing_job} ->
        stream_or_status_for_duplicate(conn, existing_job)

      {:direct, _job, response} ->
        conn = Enum.reduce(response.headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        send_resp(conn, response.status, response.body)

      {:fallback, job, reason} ->
        case AccountQueueRegistry.enqueue_prepared(job, account_queue_header(conn)) do
          :ok ->
            conn
            |> put_queue_headers(job)
            |> JobStreamController.stream_events(job, reason)

          {:rejected, limit_reason, limit, current} ->
            IdempotentStore.delete_job(job)

            conn
            |> put_queue_headers(job)
            |> admission_rejected(limit_reason, limit, current)
        end

      {:redirected, {:direct, status, headers, body, region}} ->
        conn =
          Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
          |> put_resp_header("x-aquifer-served-by-region", region)

        send_resp(conn, status, body)

      {:redirected, {:relay, request_id, region}} ->
        JobStreamController.relay_stream(conn, request_id, region)

      {:redirect_exhausted, job_id} ->
        retry_after = Redirect.exhausted_retry_after_seconds()

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(429)
        |> json(%{
          error:
            "job #{job_id}: cross-region redirect exhausted, no known-live region could help",
          limit_reason: "redirect_exhausted"
        })
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
        json(conn, duplicate_response(job.id, status))

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
        result = IdempotentStore.get_result(job_id)

        response =
          %{
            job_id: job_id,
            status: status,
            url: job.url,
            pool_id: job.pool_id,
            method: job.method,
            created_at: job.created_at,
            execute_before: job.execute_before
          }
          |> maybe_put_result(result)

        json(conn, response)
    end
  end

  defp duplicate_response(job_id, status \\ nil) do
    status = status || IdempotentStore.get_status(job_id) || "queued"
    result = IdempotentStore.get_result(job_id)

    %{job_id: job_id, status: status, duplicate: true}
    |> maybe_put_result(result)
  end

  defp maybe_put_result(payload, nil), do: payload
  defp maybe_put_result(payload, result), do: Map.put(payload, :result, result)

  defp admission_rejected(conn, reason, limit, current) do
    retry_after = Admission.retry_after_seconds()

    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_status(429)
    |> json(%{
      error: "admission rejected: #{reason} (current #{current}, limit #{limit})",
      limit_reason: reason,
      limit: limit,
      current: current
    })
  end

  defp put_queue_headers(conn, job) do
    snapshot = AccountQueueRegistry.queue_snapshot(job)
    pressure = :erlang.float_to_binary(snapshot.admission_pressure * 1.0, decimals: 3)

    conn
    |> put_resp_header("x-aqueduct-active-queues", to_string(snapshot.active_queues))
    |> put_resp_header("x-aqueduct-upstream-backlog", to_string(snapshot.upstream_backlog))
    |> put_resp_header("x-aqueduct-queue-backlog", to_string(snapshot.queue_backlog))
    |> put_resp_header("x-aqueduct-admission-pressure", pressure)
    |> put_resp_header("x-ezthrottle-active-queues", to_string(snapshot.active_queues))
    |> put_resp_header("x-ezthrottle-upstream-backlog", to_string(snapshot.upstream_backlog))
    |> put_resp_header("x-ezthrottle-queue-backlog", to_string(snapshot.queue_backlog))
    |> put_resp_header("x-ezthrottle-admission-pressure", pressure)
  end

  # Reads X-Aqueduct-Account-Queue first, falling back to
  # X-EZThrottle-Account-Queue — this is the client-facing request-header
  # path for opting a job into per-tenant isolation directly. It previously
  # didn't exist at all: account-queue mode could only be toggled by the
  # *upstream's response* headers or static config, with no way for the
  # client submitting the job to ask for isolation up front.
  # X-Aqueduct-Max-Retries (or X-EZThrottle-Max-Retries) overrides the body's
  # max_retries; Job.new/1 validates it.
  defp with_max_retries_header(conn, params) do
    case Plug.Conn.get_req_header(conn, "x-aqueduct-max-retries") ++
           Plug.Conn.get_req_header(conn, "x-ezthrottle-max-retries") do
      [value | _] -> Map.put(params, "max_retries", value)
      [] -> params
    end
  end

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
