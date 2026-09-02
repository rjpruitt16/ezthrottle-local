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
  alias EzthrottleLocal.Redirect

  @default_breaker_retry_multiplier 3
  @default_breaker_cooldown_seconds 5
  @default_direct_attempt_timeout_ms 3_000
  @default_queue_codes "429"
  @default_reroute_codes "503"

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
    * `{:fallback, job, reason}` -- persisted but not dispatched; caller
      should AccountQueueRegistry.enqueue/2 it and stream the result
      normally. reason is `%{reason: string, status: integer | nil}` --
      status is only set when a real upstream response was actually
      received (an overload signal), nil for a skipped or timed-out
      attempt -- surfaced to the caller as a proxy_fallback SSE event
      before the normal queued/dispatching/terminal sequence, mirrors
      Aquifer's ProxyOutcome.FallbackReason/FallbackStatus.
    * `{:redirected, outcome}` -- cross-region redirect (EzthrottleLocal.Redirect)
      found a sibling region that could help. `outcome` is
      `{:direct, status, headers, body, region}` (relay verbatim, tag with
      X-Aquifer-Served-By-Region) or `{:relay, request_id, region}` (target
      accepted it into its own queue -- caller should relay that live
      stream, announcing a "rerouted" event first).
    * `{:redirect_exhausted, job_id}` -- cross-region redirect is
      configured but no known-live region could help either. Caller must
      hard-error (429 + Retry-After), never a silent local queue.
  """
  def attempt_direct(params), do: attempt_direct(params, nil)

  def attempt_direct(params, account_queue_header) do
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
                attempt_dispatch_or_fallback(job, account_queue_header)
            end
        end
    end
  end

  # Pool-routed jobs have no single canonical upstream to try directly --
  # pool routing's whole premise (spread across members, one might be
  # unhealthy) is in tension with "there's one upstream, try it". Fall
  # straight back to queue+stream, same as any job the caller couldn't
  # attempt directly. Also skips cross-region redirect consideration: a
  # redirected target instance has no reason to share the same pool
  # membership, so there's no single canonical destination to even try
  # there either.
  defp attempt_dispatch_or_fallback(%Job{pool_id: pool_id} = job, _account_queue_header)
       when is_binary(pool_id) do
    {:fallback, job, %{reason: "pool_routed", status: nil}}
  end

  # breaker_open? and queue_active? are checked separately, not OR'd
  # together into one branch: queue_active? alone (breaker closed) is
  # routine pacing under a configured rps limit -- working exactly as
  # designed, not a signal anything needs rerouting -- so it never tries
  # redirect, only ever falls back to this instance's own queue exactly as
  # it always has. breaker_open? means an actual overload signal tripped
  # it; whether THAT retry also tries redirect depends on which kind of
  # signal tripped it (breaker_kind), decided below the same way a fresh
  # overload response decides it.
  defp attempt_dispatch_or_fallback(%Job{} = job, account_queue_header) do
    cond do
      AccountQueueRegistry.breaker_open?(job) ->
        try_redirect = AccountQueueRegistry.breaker_kind(job) == :reroute
        maybe_redirect_or_fallback(job, account_queue_header, "domain_degraded", nil, try_redirect)

      AccountQueueRegistry.queue_active?(job) ->
        maybe_redirect_or_fallback(job, account_queue_header, "domain_degraded", nil, false)

      true ->
        case AccountQueue.make_request(job, job.url, 0, 0, :direct, direct_attempt_timeout_ms()) do
          {:ok, response} ->
            handle_direct_response(job, account_queue_header, response)

          {:error, _reason} ->
            maybe_redirect_or_fallback(job, account_queue_header, "upstream_unreachable", nil, true)
        end
    end
  end

  # Tries cross-region redirect first (EzthrottleLocal.Redirect) when
  # try_redirect is true, so a caller only ever falls back to its own
  # local queue after a sibling region genuinely couldn't take the job
  # either. try_redirect is false for pool_routed and for a domain_degraded
  # fallback caused by bare queue_active? (routine local backlog, breaker
  # closed -- not a signal anything is regionally degraded) or a
  # queue-kind breaker trip (see attempt_dispatch_or_fallback/2). Mirrors
  # Aquifer's fallbackOutcome exactly, including the direct_only cleanup:
  # direct_only is only ever true on an internal cross-region redirect hop
  # (a real caller never sets it) -- when set, this instance has been
  # explicitly told not to commit to its own local queue, so the job row
  # check_or_insert already wrote gets deleted, mirroring the
  # admission-rejection cleanup above. Without this, an origin's redirect
  # tour trying several regions in sequence could leave the SAME job
  # durably committed in more than one place.
  defp maybe_redirect_or_fallback(job, _account_queue_header, reason, status, false) do
    if job.direct_only do
      IdempotentStore.delete_job(job)
    end

    {:fallback, job, %{reason: reason, status: status}}
  end

  defp maybe_redirect_or_fallback(job, account_queue_header, reason, status, true) do
    case Redirect.attempt_redirect(job, account_queue_header) do
      {:succeeded, outcome} ->
        # The real job now lives on the target region under its own ID --
        # this instance's own row is moot the moment a sibling takes it, the
        # same way :exhausted's cleanup below is. Without this, the row
        # sits at status :queued forever: a later retry of the same
        # idempotent_key would find it via check_or_insert, see :queued
        # (never :completed -- nothing here ever transitions it), and open
        # a stream subscribed to a PubSub topic nothing will ever broadcast
        # to again, hanging on keepalives indefinitely.
        IdempotentStore.delete_job(job)
        {:redirected, outcome}

      :exhausted ->
        IdempotentStore.delete_job(job)
        {:redirect_exhausted, job.id}

      :not_applicable ->
        if job.direct_only do
          IdempotentStore.delete_job(job)
        end

        {:fallback, job, %{reason: reason, status: status}}
    end
  end

  defp handle_direct_response(job, account_queue_header, response) do
    case classify_overload(response.headers, response.status) do
      kind when kind in [:queue, :reroute] ->
        AccountQueueRegistry.trip_breaker(job, breaker_cooldown(response.headers), kind)
        maybe_redirect_or_fallback(job, account_queue_header, "upstream_overloaded", response.status, kind == :reroute)

      nil ->
        # The upstream can proactively ask to be routed through the durable
        # queue going forward -- X-Aqueduct-Queue-Active: true -- even on an
        # otherwise-healthy response, e.g. "I'm nearing capacity, stop firing
        # directly at me." Unlike classify_overload/2, this response is
        # still a real, valid answer already in hand: it's relayed to the
        # caller as normal below, only future requests to this domain start
        # queuing -- always :queue kind, never :reroute, matching its own
        # name.
        if AccountQueue.pacing_header(response.headers, "queue-active") == "true" do
          AccountQueueRegistry.trip_breaker(job, breaker_cooldown(response.headers), :queue)
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

  @doc """
  Decides whether a direct-dispatch response means "hand this off to the
  durable, paced queue instead" -- and if so, whether to also try
  cross-region redirect first (EzthrottleLocal.Redirect) or just queue
  locally. Returns nil for anything not classified as overload -- relayed
  to the caller as a normal, if unfortunate, direct response, same as any
  other non-2xx status an upstream might legitimately return. Distinct
  from dispatch_with_retries/8's own >=500-only retry classification: a
  direct attempt has no retry loop of its own, so either kind means fall
  back, not retry inline.

  A real, deliberate scope narrowing from earlier behavior (every 5xx used
  to mean the same thing): 429 is usually a global per-key rate limit, not
  a regional one, so rerouting to a sibling region wouldn't even help --
  reroute is reserved for signals that plausibly ARE regional (503 by
  default).

  X-Aqueduct-Queue-Codes / X-Aqueduct-Reroute-Codes response headers (same
  dual-namespace lookup as every other Aqueduct header) let the upstream
  configure its own sets, comma-separated, each entry either a literal
  code ("502") or an HTTP status class ("5xx") -- due diligence is on the
  upstream to say so if it uses something nonstandard; defaults are
  deliberately narrow (429 -> queue, 503 -> reroute) rather than sweeping
  in every 5xx.

  An ORCA overload signal (Orca.rps returning non-nil) is always
  reroute-eligible -- sustained backend load reported this way is commonly
  instance/pool-specific, unlike a generic rate limit.
  """
  def classify_overload(headers, status) do
    cond do
      Orca.rps(headers) != nil ->
        :reroute

      code_list_matches?(parse_code_list(header_or_default(headers, "reroute-codes", @default_reroute_codes)), status) ->
        :reroute

      code_list_matches?(parse_code_list(header_or_default(headers, "queue-codes", @default_queue_codes)), status) ->
        :queue

      true ->
        nil
    end
  end

  defp header_or_default(headers, name, default) do
    case AccountQueue.pacing_header(headers, name) do
      nil -> default
      val -> val
    end
  end

  @doc """
  Parses a comma-separated list of literal status codes and/or HTTP status
  classes ("5xx" matches every 500-599) into matcher tuples, either
  {:literal, code} or {:class, digit}.
  """
  def parse_code_list(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_code_entry/1)
  end

  defp parse_code_entry(<<d, x1, x2>>) when x1 in [?x, ?X] and x2 in [?x, ?X] and d in ?1..?5 do
    [{:class, d - ?0}]
  end

  defp parse_code_entry(entry) do
    case Integer.parse(entry) do
      {n, ""} -> [{:literal, n}]
      _ -> []
    end
  end

  def code_list_matches?(matchers, status) do
    Enum.any?(matchers, fn
      {:class, digit} -> div(status, 100) == digit
      {:literal, code} -> status == code
    end)
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
