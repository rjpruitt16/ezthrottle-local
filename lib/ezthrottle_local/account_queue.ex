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
  alias EzthrottleLocal.Webhook
  alias EzthrottleLocal.Pool

  @idle_timeout_ms 300_000
  @min_rps 0.5
  @position_broadcast_ms 2_000

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
          {:no_pool_members, job, remaining_queue} ->
            # Pool-backed queue with nothing registered -- fail this job
            # immediately rather than blocking the whole queue behind an
            # empty pool, then keep processing whatever's next.
            Metrics.queue_depth(state.upstream, :queue.len(remaining_queue))
            fail_immediately(job, "no pool members registered")
            send(self(), :process_next)
            {:noreply, %{state | queue: remaining_queue}, @idle_timeout_ms}

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
    {{:value, job}, remaining_queue} = :queue.out(state.queue)

    case Pool.pick(pool_pid) do
      nil -> {:no_pool_members, job, remaining_queue}
      member -> {:ok, job, member.address, member, remaining_queue}
    end
  end

  # Fails a job that never even attempted dispatch (e.g. an empty pool) --
  # mirrors the terminal-failure shape of execute/8's error branch, just
  # without a request ever having gone out.
  defp fail_immediately(%Job{} = job, reason) do
    IdempotentStore.update_status(job.id, :failed)
    upstream = Metrics.upstream(job.pool_id || job.url || "unknown")
    Metrics.job_failed(job.user_id, upstream, reason)

    Phoenix.PubSub.broadcast(
      EzthrottleLocal.PubSub,
      "job:#{job.id}",
      {:job_event, %{event: "failed", job_id: job.id, reason: reason}}
    )

    maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, %{
      job_id: job.id,
      status: "failed",
      reason: reason
    })
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

    result = make_request(job, dispatch_url, flow_rate, max_concurrent, queue_key)

    case result do
      {:ok, %{status: status, body: body, headers: resp_headers}} ->
        record_pool_outcome(pool_pid, member_id, status)

        rps = parse_rps_header(resp_headers)
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

      {:error, reason} ->
        if pool_pid && member_id, do: Pool.record_failure(pool_pid, member_id)

        GenServer.call(parent, {:job_done, nil, nil, nil})

        IdempotentStore.update_status(job.id, :failed)
        Metrics.job_failed(job.user_id, upstream, inspect(reason))

        Phoenix.PubSub.broadcast(
          EzthrottleLocal.PubSub,
          "job:#{job.id}",
          {:job_event,
           %{
             event: "failed",
             job_id: job.id,
             reason: inspect(reason)
           }}
        )

        maybe_deliver_webhook(IdempotentStore.get_delivery_mode(job.id), job, %{
          job_id: job.id,
          status: "failed",
          reason: inspect(reason)
        })
    end
  end

  # A dispatch attempt that comes back with a 5xx still "succeeded" from
  # httpc's point of view (a real response, not a connection error) but
  # is a genuine failure for reputation purposes -- mirrors Aquifer's
  # execute() checking resp.StatusCode >= 500 after a successful HTTP
  # round trip, not just the connection-error branch.
  defp record_pool_outcome(nil, _member_id, _status), do: :ok
  defp record_pool_outcome(_pool_pid, nil, _status), do: :ok

  defp record_pool_outcome(pool_pid, member_id, status) when status >= 500,
    do: Pool.record_failure(pool_pid, member_id)

  defp record_pool_outcome(pool_pid, member_id, _status),
    do: Pool.record_success(pool_pid, member_id)

  defp maybe_deliver_webhook(:stream, _job, _payload), do: :ok
  defp maybe_deliver_webhook(_mode, job, payload), do: Webhook.deliver(job.webhook_url, payload)

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

    headers =
      headers_to_charlist(Enum.map(job.headers, fn {k, v} -> {k, v} end) ++ metric_headers)

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
