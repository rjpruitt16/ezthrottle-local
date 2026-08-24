defmodule EzthrottleLocal.AccountQueue do
  @moduledoc """
  GenServer per user_id + api_key scoped to a destination URL.
  Paces outbound requests at the configured RPS.
  Adapts RPS in real time via X-EZTHROTTLE-RPS response headers.
  Delivers results to the job's webhook_url.
  """

  use GenServer

  require Logger

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Metrics
  alias EzthrottleLocal.AccountQueueRegistry
  alias EzthrottleLocal.Pool

  @idle_timeout_ms 300_000
  @min_rps 0.5
  @position_broadcast_ms 2_000
  @max_retries 4

  defstruct [
    :queue_key,
    :upstream,
    :url_actor,
    :pool_pid,
    rps: 2.0,
    max_concurrent: 1,
    queue: :queue.new(),
    in_flight: 0,
    last_request_at: 0
  ]

  # ---- Public API ----

  def start_link(opts) do
    queue_key = Keyword.fetch!(opts, :queue_key)
    upstream = Keyword.fetch!(opts, :upstream)
    rps = Keyword.get(opts, :rps, 2.0)
    max_concurrent = Keyword.get(opts, :max_concurrent, 1)
    url_actor = Keyword.get(opts, :url_actor)
    pool_pid = Keyword.get(opts, :pool_pid)

    GenServer.start_link(__MODULE__, %{
      queue_key: queue_key,
      upstream: upstream,
      url_actor: url_actor,
      rps: rps,
      max_concurrent: max_concurrent,
      pool_pid: pool_pid
    })
  end

  def enqueue(pid, %Job{} = job) do
    GenServer.cast(pid, {:enqueue, job})
  end

  def update_rps(pid, rps) do
    GenServer.cast(pid, {:update_rps, rps})
  end

  @doc "Current dispatch rate -- used by UrlActor's aggregate-budget check to read every sibling queue's live rate."
  def get_rps(pid), do: GenServer.call(pid, :get_rps)

  def update_max_concurrent(pid, max) do
    GenServer.cast(pid, {:update_max_concurrent, max})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{
        queue_key: queue_key,
        upstream: upstream,
        url_actor: url_actor,
        rps: rps,
        max_concurrent: max_concurrent,
        pool_pid: pool_pid
      }) do
    state = %__MODULE__{
      queue_key: queue_key,
      upstream: upstream,
      url_actor: url_actor,
      rps: rps,
      max_concurrent: max_concurrent,
      pool_pid: pool_pid
    }

    schedule_position_broadcast()
    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:enqueue, job}, state) do
    new_queue = :queue.in(job, state.queue)
    new_state = %{state | queue: new_queue}
    Metrics.queue_depth(state.upstream, :queue.len(new_queue))
    send(self(), :process_next)
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    safe_rps = max(rps, @min_rps)
    Metrics.flow_rate(state.upstream, safe_rps)
    {:noreply, %{state | rps: safe_rps}, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:update_max_concurrent, max}, state) do
    {:noreply, %{state | max_concurrent: max}, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:process_next, state) do
    cond do
      state.in_flight >= state.max_concurrent ->
        {:noreply, state, @idle_timeout_ms}

      :queue.is_empty(state.queue) ->
        {:noreply, state, @idle_timeout_ms}

      true ->
        case resolve_target(state) do
          :no_pool_members ->
            # Pool-backed queue with no live members yet. This can happen
            # during process restart before workers have had time to
            # heartbeat back in, so keep the head job queued and retry
            # later instead of turning temporary absence into terminal
            # failure.
            Process.send_after(self(), :process_next, no_pool_members_retry_ms())
            {:noreply, state, @idle_timeout_ms}

          {:ok, job, dispatch_url, member, remaining_queue} ->
            # Enforce RPS with jitter to prevent synchronized bursts across queues
            now = System.system_time(:millisecond)
            interval_ms = trunc(1_000 / state.rps)
            jitter_ms = :rand.uniform(trunc(interval_ms * 0.1) + 1)
            elapsed = now - state.last_request_at

            if elapsed < interval_ms do
              Process.sleep(interval_ms - elapsed + jitter_ms)
            end

            new_state = %{
              state
              | queue: remaining_queue,
                in_flight: state.in_flight + 1,
                last_request_at: System.system_time(:millisecond)
            }

            Metrics.queue_depth(state.upstream, :queue.len(remaining_queue))

            # Execute in a Task so the GenServer stays responsive
            parent = self()
            pool_pid = state.pool_pid
            member_id = member && member.id

            Task.start(fn ->
              execute(
                job,
                dispatch_url,
                parent,
                state.rps,
                state.max_concurrent,
                state.queue_key,
                pool_pid,
                member_id
              )
            end)

            {:noreply, new_state, @idle_timeout_ms}
        end
    end
  end

  @impl true
  def handle_info({:job_done, rps_header, max_concurrent_header}, state) do
    handle_info({:job_done, rps_header, max_concurrent_header, nil}, state)
  end

  @impl true
  def handle_info({:job_done, rps_header, max_concurrent_header, account_queue_header}, state) do
    new_state = apply_job_done(state, rps_header, max_concurrent_header, account_queue_header)

    send(self(), :process_next)
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:broadcast_positions, state) do
    state.queue
    |> :queue.to_list()
    |> Enum.with_index(1)
    |> Enum.each(fn {job, position} ->
      Phoenix.PubSub.broadcast(
        EzthrottleLocal.PubSub,
        "job:#{job.id}",
        {:job_event,
         %{
           event: "position",
           job_id: job.id,
           position: position
         }}
      )
    end)

    schedule_position_broadcast()
    {:noreply, state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    if :queue.is_empty(state.queue) and state.in_flight == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_timeout_ms}
    end
  end

  @impl true
  def handle_call(
        {:job_done, rps_header, max_concurrent_header, account_queue_header},
        _from,
        state
      ) do
    new_state = apply_job_done(state, rps_header, max_concurrent_header, account_queue_header)

    send(self(), :process_next)
    {:reply, :ok, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:get_rps, _from, state), do: {:reply, state.rps, state}

  # ---- Private ----

  # Pool-backed queue: resolve via weighted selection. nil url/pool_pid on
  # a plain queue means dispatch straight to the job's own fixed url, same
  # as before pools existed.
  defp resolve_target(%{pool_pid: nil} = state) do
    {{:value, job}, remaining_queue} = :queue.out(state.queue)
    {:ok, job, job.url, nil, remaining_queue}
  end

  defp resolve_target(%{pool_pid: pool_pid} = state) do
    case Pool.pick(pool_pid) do
      nil ->
        :no_pool_members

      member ->
        {{:value, job}, remaining_queue} = :queue.out(state.queue)
        {:ok, job, member.address, member, remaining_queue}
    end
  end

  defp execute(
         %Job{} = job,
         dispatch_url,
         parent,
         flow_rate,
         max_concurrent,
         queue_key,
         pool_pid,
         member_id
       ) do
    started_at = System.monotonic_time(:millisecond)
    upstream = Metrics.upstream(job.pool_id || dispatch_url)

    IdempotentStore.update_status(job.id, :in_flight)
    Metrics.job_dispatched(job.user_id, upstream)

    Phoenix.PubSub.broadcast(
      EzthrottleLocal.PubSub,
      "job:#{job.id}",
      {:job_event,
       %{
         event: "dispatching",
         job_id: job.id
       }}
    )

    result =
      dispatch_with_retries(
        job,
        dispatch_url,
        flow_rate,
        max_concurrent,
        queue_key,
        pool_pid,
        member_id,
        0
      )

    case result do
      {:ok, %{status: status, body: body, headers: resp_headers}, successful_member_id} ->
        if pool_pid && successful_member_id,
          do: Pool.record_success(pool_pid, successful_member_id)

        rps = parse_rps_header(resp_headers) || EzthrottleLocal.Orca.rps(resp_headers)
        max_concurrent = parse_max_concurrent_header(resp_headers)
        account_queue = parse_account_queue_header(resp_headers)
        GenServer.call(parent, {:job_done, rps, max_concurrent, account_queue})

        IdempotentStore.update_status(job.id, :completed)

        Metrics.job_completed(
          job.user_id,
          upstream,
          System.monotonic_time(:millisecond) - started_at
        )

        Phoenix.PubSub.broadcast(
          EzthrottleLocal.PubSub,
          "job:#{job.id}",
          {:job_event,
           %{
             event: "completed",
             job_id: job.id,
             response_status: status,
             body: body
           }}
        )

        maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, %{
          job_id: job.id,
          status: "completed",
          response_status: status,
          body: body
        })

      {:error, reason, response} ->
        GenServer.call(parent, {:job_done, nil, nil, nil})

        IdempotentStore.update_status(job.id, :failed)
        Metrics.job_failed(job.user_id, upstream, to_string(reason))

        failed_event =
          %{
            event: "failed",
            job_id: job.id,
            reason: to_string(reason)
          }
          |> maybe_put_response(response)

        Phoenix.PubSub.broadcast(
          EzthrottleLocal.PubSub,
          "job:#{job.id}",
          {:job_event, failed_event}
        )

        failed_payload =
          %{
            job_id: job.id,
            status: "failed",
            reason: to_string(reason)
          }
          |> maybe_put_response(response)

        maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, failed_payload)
    end
  end

  defp dispatch_with_retries(
         job,
         dispatch_url,
         flow_rate,
         max_concurrent,
         queue_key,
         pool_pid,
         member_id,
         attempt
       ) do
    case make_request(job, dispatch_url, flow_rate, max_concurrent, queue_key) do
      {:ok, %{status: status} = response} when status >= 500 ->
        if pool_pid && member_id, do: Pool.record_failure(pool_pid, member_id)

        if attempt < max_retries() do
          sleep_before_retry(attempt)

          case next_dispatch_target(pool_pid, dispatch_url) do
            {:ok, next_url, next_member_id} ->
              dispatch_with_retries(
                job,
                next_url,
                flow_rate,
                max_concurrent,
                queue_key,
                pool_pid,
                next_member_id,
                attempt + 1
              )

            :no_pool_members ->
              {:error, "no pool members registered", nil}
          end
        else
          {:error, "upstream returned #{status}", response}
        end

      {:ok, %{status: _status} = response} ->
        {:ok, response, member_id}

      {:error, reason} ->
        if pool_pid && member_id, do: Pool.record_failure(pool_pid, member_id)

        if attempt < max_retries() do
          sleep_before_retry(attempt)

          case next_dispatch_target(pool_pid, dispatch_url) do
            {:ok, next_url, next_member_id} ->
              dispatch_with_retries(
                job,
                next_url,
                flow_rate,
                max_concurrent,
                queue_key,
                pool_pid,
                next_member_id,
                attempt + 1
              )

            :no_pool_members ->
              {:error, "no pool members registered", nil}
          end
        else
          {:error, inspect(reason), nil}
        end
    end
  end

  defp next_dispatch_target(nil, dispatch_url), do: {:ok, dispatch_url, nil}

  defp next_dispatch_target(pool_pid, _dispatch_url) do
    case Pool.pick(pool_pid) do
      nil -> :no_pool_members
      member -> {:ok, member.address, member.id}
    end
  end

  defp maybe_put_response(payload, nil), do: payload

  defp maybe_put_response(payload, %{status: status, body: body}) do
    payload
    |> Map.put(:response_status, status)
    |> Map.put(:body, body)
  end

  # A webhook-delivery job (Job.webhook_delivery_job?/1) must never
  # enqueue its own webhook -- it flows through this same execute/8 path
  # as a regular job, so without this guard first, its own completion
  # would recursively enqueue another webhook delivery forever.
  defp maybe_deliver_webhook(_mode, %Job{webhook_url: url}, _payload) when url in [nil, ""],
    do: :ok

  defp maybe_deliver_webhook(:stream, _job, _payload), do: :ok

  defp maybe_deliver_webhook(_mode, job, payload) do
    AccountQueueRegistry.enqueue_webhook(job.id, job.user_id, job.webhook_url, payload)
  end

  defp max_retries,
    do: Application.get_env(:ezthrottle_local, :dispatch_max_retries, @max_retries)

  defp no_pool_members_retry_ms,
    do: Application.get_env(:ezthrottle_local, :no_pool_members_retry_ms, 1_000)

  defp retry_backoff_ms(attempt), do: trunc(:math.pow(2, attempt) * 1_000)

  defp sleep_before_retry(attempt) do
    Process.sleep(
      Application.get_env(:ezthrottle_local, :dispatch_retry_ms, retry_backoff_ms(attempt))
    )
  end

  defp schedule_position_broadcast do
    Process.send_after(self(), :broadcast_positions, @position_broadcast_ms)
  end

  defp make_request(%Job{} = job, dispatch_url, flow_rate, max_concurrent, queue_key) do
    %{total_jobs: total, queue_depth: depth} = EzthrottleLocal.IdempotentStore.counts()
    url = String.to_charlist(dispatch_url)
    account_queue_enabled = queue_key != :shared
    queue_key_header = if account_queue_enabled, do: to_string(queue_key), else: "shared"

    metric_headers = [
      {"x-aqueduct-total-jobs", to_string(total)},
      {"x-aqueduct-queue-depth", to_string(depth)},
      {"x-aqueduct-flow-rate", :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-aquifer-total-jobs", to_string(total)},
      {"x-aquifer-queue-depth", to_string(depth)},
      {"x-aquifer-flow-rate", :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-ezthrottle-current-total-jobs", to_string(total)},
      {"x-ezthrottle-current-queue-depth", to_string(depth)},
      {"x-ezthrottle-current-flow-rate",
       :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])},
      {"x-ezthrottle-current-max-concurrent", to_string(max_concurrent)},
      {"x-ezthrottle-current-account-queue-enabled", to_string(account_queue_enabled)},
      {"x-ezthrottle-current-queue-key", queue_key_header},
      {"x-ezthrottle-current-queue-mode",
       if(account_queue_enabled, do: "account", else: "shared")}
    ]

    job_headers = Enum.map(job.headers, fn {k, v} -> {k, v} end)
    metric_headers = maybe_add_orca_opt_in(metric_headers, job_headers)
    l8_headers = maybe_l8_headers(job, dispatch_url)

    headers = headers_to_charlist(job_headers ++ metric_headers ++ l8_headers)

    method =
      case String.upcase(job.method) do
        "GET" -> :get
        "POST" -> :post
        "PUT" -> :put
        "PATCH" -> :patch
        "DELETE" -> :delete
        _ -> :get
      end

    # :httpc uses {url, headers} for bodyless methods, {url, headers, content_type, body} for body methods
    request =
      if method in [:post, :put, :patch] do
        body = job.body || ""
        {url, headers, ~c"application/json", body}
      else
        {url, headers}
      end

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        {:ok,
         %{
           status: status,
           body: to_string(resp_body),
           headers: charlist_headers_to_map(resp_headers)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # L8 signing proves EZThrottle's identity to the *receiver* of a
  # webhook -- it has no meaning for forward dispatch to an arbitrary
  # upstream API, so this only applies when the job being dispatched is
  # itself a webhook delivery (see Job.webhook_delivery_job?/1). Mirrors
  # Aquifer's account_queue.go makeRequest.
  defp maybe_l8_headers(%Job{webhook_url: url} = job, dispatch_url) when url in [nil, ""] do
    EzthrottleLocal.L8.ensure_trust(dispatch_url)

    if EzthrottleLocal.L8.is_trusted?(dispatch_url) do
      EzthrottleLocal.L8.sign_headers(job.body || "") |> Map.to_list()
    else
      []
    end
  end

  defp maybe_l8_headers(_job, _dispatch_url), do: []

  # Opts every dispatch into ORCA reporting by default, unless the caller
  # already set the format header explicitly -- mirrors Aquifer's
  # account_queue.go, which sends this on every dispatch too.
  defp maybe_add_orca_opt_in(metric_headers, job_headers) do
    orca_header = EzthrottleLocal.Orca.request_header_name()

    already_set? =
      Enum.any?(job_headers, fn {k, _v} -> String.downcase(k) == orca_header end)

    if already_set? do
      metric_headers
    else
      [{orca_header, "TEXT"} | metric_headers]
    end
  end

  defp headers_to_charlist(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp charlist_headers_to_map(headers) do
    Enum.reduce(headers, %{}, fn {k, v}, acc ->
      Map.put(acc, k |> to_string() |> String.downcase(), to_string(v))
    end)
  end

  # Reads X-Aqueduct-<name> first, falling back to X-EZThrottle-<name> —
  # same dual-namespace precedence Aquifer uses (X-Aqueduct-* is the
  # protocol name, X-Aquifer-*/X-EZThrottle-* are product aliases), so a
  # backend speaking either protocol's headers is understood.
  defp pacing_header(headers, name) when is_map(headers) do
    case Map.get(headers, "x-aqueduct-#{name}") do
      nil -> Map.get(headers, "x-ezthrottle-#{name}")
      val -> val
    end
  end

  defp pacing_header(_headers, _name), do: nil

  defp parse_rps_header(headers) do
    case pacing_header(headers, "rps") do
      nil ->
        nil

      val ->
        case Float.parse(val) do
          {rps, _} -> rps
          :error -> nil
        end
    end
  end

  defp parse_max_concurrent_header(headers) do
    case pacing_header(headers, "max-concurrent") do
      nil ->
        nil

      val ->
        case Integer.parse(val) do
          {max, _} -> max
          :error -> nil
        end
    end
  end

  defp parse_account_queue_header(headers) do
    case pacing_header(headers, "account-queue") do
      nil ->
        nil

      val ->
        case val |> String.trim() |> String.downcase() do
          mode when mode in ["enabled", "disabled"] -> mode
          _ -> nil
        end
    end
  end

  defp maybe_update_rps(state, nil), do: state
  defp maybe_update_rps(state, rps), do: %{state | rps: max(rps, @min_rps)}

  defp maybe_update_max_concurrent(state, nil), do: state
  defp maybe_update_max_concurrent(state, max), do: %{state | max_concurrent: max}

  defp apply_job_done(state, rps_header, max_concurrent_header, account_queue_header) do
    maybe_update_account_queue_mode(state, account_queue_header)

    new_state =
      state
      |> maybe_update_rps(rps_header)
      |> maybe_update_max_concurrent(max_concurrent_header)
      |> Map.put(:in_flight, max(state.in_flight - 1, 0))

    if new_state.rps != state.rps do
      Metrics.flow_rate(state.upstream, new_state.rps)
    end

    new_state
  end

  defp maybe_update_account_queue_mode(%{url_actor: nil}, _mode), do: :ok
  defp maybe_update_account_queue_mode(_state, nil), do: :ok

  defp maybe_update_account_queue_mode(%{url_actor: url_actor}, mode) do
    GenServer.call(url_actor, {:account_queue_header, mode})
    :ok
  end
end
