defmodule EzthrottleLocal.Proxy do
  @moduledoc """
  Proxy mode: try the upstream directly and synchronously first; fall back
  to the existing durable-queue-and-SSE path only on failure or an
  overload signal. Mirrors Aquifer's proxy.go -- reuses
  AccountQueue.make_request/6, the same persistence/admission sequence
  JobController.create/2 already runs inline, and the existing
  AccountQueueRegistry/UrlActor breaker + dispatch machinery, rather than
  a parallel implementation.
  """

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Admission
  alias EzthrottleLocal.Metrics
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.Orca

  @default_breaker_retry_multiplier 3
  @default_breaker_cooldown_seconds 5
  @default_direct_attempt_timeout_ms 3_000

  @doc """
  Attempts a direct, synchronous dispatch for this request. Returns:

    * `{:error, reason}` -- validation failure, same contract as create/2
    * `{:admission_rejected, reason, limit, current}` -- admission
      rejected it, same contract as create/2's 429 branch
    * `{:duplicate, existing_job}` -- an idempotent-key repeat; the caller
      must check IdempotentStore.get_status/1 itself, since existing_job's
      own :status field is frozen at construction time (see Job)
    * `{:direct, job, response}` -- completed synchronously, response is
      `%{status:, body:, headers:}` for the caller to relay verbatim
    * `{:fallback, job}` -- persisted but not dispatched; caller should
      AccountQueueRegistry.enqueue/2 it and stream the result normally
  """
  def attempt_direct(params) do
    case Job.new(params) do
      {:error, reason} ->
        {:error, reason}

      {:ok, job} ->
        case IdempotentStore.check_or_insert(job) do
          {:duplicate, existing_id} ->
            {:duplicate, IdempotentStore.get_job(existing_id)}

          :ok ->
            case Admission.check() do
              {:rejected, reason, limit, current} ->
                IdempotentStore.delete_job(job)
                {:admission_rejected, reason, limit, current}

              :ok ->
                Metrics.job_queued(job.user_id, Metrics.upstream(job.url))
                attempt_dispatch_or_fallback(job)
            end
        end
    end
  end

  # Pool-routed jobs have no single canonical upstream to try directly --
  # pool routing's whole premise (spread across members, one might be
  # unhealthy) is in tension with "there's one upstream, try it". Fall
  # straight back to queue+stream, same as any job the caller couldn't
  # attempt directly.
  defp attempt_dispatch_or_fallback(%Job{pool_id: pool_id} = job) when is_binary(pool_id) do
    {:fallback, job}
  end

  defp attempt_dispatch_or_fallback(%Job{} = job) do
    if AccountQueueRegistry.breaker_open?(job) or AccountQueueRegistry.queue_active?(job) do
      {:fallback, job}
    else
      case AccountQueue.make_request(job, job.url, 0, 0, :direct, direct_attempt_timeout_ms()) do
        {:ok, response} ->
          handle_direct_response(job, response)

        {:error, _reason} ->
          {:fallback, job}
      end
    end
  end

  defp handle_direct_response(job, response) do
    if overload?(response) do
      AccountQueueRegistry.trip_breaker(job, breaker_cooldown(response.headers))
      {:fallback, job}
    else
      # The upstream can proactively ask to be routed through the durable
      # queue going forward -- X-Aqueduct-Queue-Active: true -- even on an
      # otherwise-healthy response, e.g. "I'm nearing capacity, stop firing
      # directly at me." Unlike overload?/1, this response is still a real,
      # valid answer already in hand: it's relayed to the caller as normal
      # below, only future requests to this domain start queuing.
      if AccountQueue.pacing_header(response.headers, "queue-active") == "true" do
        AccountQueueRegistry.trip_breaker(job, breaker_cooldown(response.headers))
      end

      IdempotentStore.update_status(job.id, :completed)

      Phoenix.PubSub.broadcast(
        EzthrottleLocal.PubSub,
        "job:#{job.id}",
        {:job_event,
         %{event: "completed", job_id: job.id, response_status: response.status, body: response.body}}
      )

      AccountQueueRegistry.enqueue_webhook(job.id, job.user_id, job.webhook_url, %{
        job_id: job.id,
        status: "completed",
        response_status: response.status,
        body: response.body
      })

      {:direct, job, response}
    end
  end

  @doc "429/5xx/ORCA-overload check on a make_request response. Distinct from dispatch_with_retries/8's own >=500-only retry classification: a direct attempt has no retry loop of its own, so any of these means fall back, not retry inline."
  def overload?(%{status: status, headers: headers}) do
    status == 429 or status >= 500 or Orca.rps(headers) != nil
  end

  @doc """
  How long to trip a domain's breaker for after an overload signal --
  anchored to the upstream's own Retry-After header when it sends one
  (times a configurable safety multiplier), falling back to a fixed
  configured default otherwise, since 5xx/timeout/ORCA signals don't carry
  that header. Mirrors Aquifer's breakerCooldown exactly.
  """
  def breaker_cooldown(headers) do
    case Map.get(headers, "retry-after") do
      nil ->
        default_cooldown_ms()

      raw ->
        case Integer.parse(raw) do
          {secs, _} when secs > 0 -> secs * retry_multiplier() * 1_000
          _ -> default_cooldown_ms()
        end
    end
  end

  defp retry_multiplier,
    do:
      Application.get_env(
        :ezthrottle_local,
        :proxy_breaker_retry_multiplier,
        @default_breaker_retry_multiplier
      )

  defp default_cooldown_ms,
    do:
      Application.get_env(
        :ezthrottle_local,
        :proxy_breaker_default_cooldown_seconds,
        @default_breaker_cooldown_seconds
      ) * 1_000

  defp direct_attempt_timeout_ms,
    do:
      Application.get_env(
        :ezthrottle_local,
        :proxy_direct_attempt_timeout_ms,
        @default_direct_attempt_timeout_ms
      )
end
