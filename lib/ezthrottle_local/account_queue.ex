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
  alias EzthrottleLocal.Webhook

  @idle_timeout_ms 300_000
  @min_rps 0.5

  defstruct [
    :queue_key,
    rps: 2.0,
    max_concurrent: 1,
    queue: :queue.new(),
    in_flight: 0,
    last_request_at: 0
  ]

  # ---- Public API ----

  def start_link(opts) do
    queue_key = Keyword.fetch!(opts, :queue_key)
    rps = Keyword.get(opts, :rps, 2.0)
    max_concurrent = Keyword.get(opts, :max_concurrent, 1)
    GenServer.start_link(__MODULE__, %{queue_key: queue_key, rps: rps, max_concurrent: max_concurrent})
  end

  def enqueue(pid, %Job{} = job) do
    GenServer.cast(pid, {:enqueue, job})
  end

  def update_rps(pid, rps) do
    GenServer.cast(pid, {:update_rps, rps})
  end

  def update_max_concurrent(pid, max) do
    GenServer.cast(pid, {:update_max_concurrent, max})
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(%{queue_key: queue_key, rps: rps, max_concurrent: max_concurrent}) do
    state = %__MODULE__{
      queue_key: queue_key,
      rps: rps,
      max_concurrent: max_concurrent
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:enqueue, job}, state) do
    new_queue = :queue.in(job, state.queue)
    new_state = %{state | queue: new_queue}
    send(self(), :process_next)
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:update_rps, rps}, state) do
    safe_rps = max(rps, @min_rps)
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
        {{:value, job}, remaining_queue} = :queue.out(state.queue)

        # Enforce RPS with jitter to prevent synchronized bursts across queues
        now = System.system_time(:millisecond)
        interval_ms = trunc(1_000 / state.rps)
        jitter_ms = :rand.uniform(trunc(interval_ms * 0.1) + 1)
        elapsed = now - state.last_request_at

        if elapsed < interval_ms do
          Process.sleep(interval_ms - elapsed + jitter_ms)
        end

        new_state = %{state |
          queue: remaining_queue,
          in_flight: state.in_flight + 1,
          last_request_at: System.system_time(:millisecond)
        }

        # Execute in a Task so the GenServer stays responsive
        parent = self()
        Task.start(fn -> execute(job, parent, state.rps) end)

        {:noreply, new_state, @idle_timeout_ms}
    end
  end

  @impl true
  def handle_info({:job_done, rps_header, max_concurrent_header}, state) do
    new_state = state
    |> maybe_update_rps(rps_header)
    |> maybe_update_max_concurrent(max_concurrent_header)
    |> Map.put(:in_flight, max(state.in_flight - 1, 0))

    send(self(), :process_next)
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    if :queue.is_empty(state.queue) and state.in_flight == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_timeout_ms}
    end
  end

  # ---- Private ----

  defp execute(%Job{} = job, parent, flow_rate) do
    result = make_request(job, flow_rate)

    case result do
      {:ok, %{status: status, body: body, headers: resp_headers}} ->
        IdempotentStore.update_status(job.id, :completed)
        Webhook.deliver(job.webhook_url, %{
          job_id: job.id,
          status: "completed",
          response_status: status,
          body: body
        })

        rps = parse_rps_header(resp_headers)
        max_concurrent = parse_max_concurrent_header(resp_headers)
        send(parent, {:job_done, rps, max_concurrent})

      {:error, reason} ->
        IdempotentStore.update_status(job.id, :failed)
        Webhook.deliver(job.webhook_url, %{
          job_id: job.id,
          status: "failed",
          reason: inspect(reason)
        })

        send(parent, {:job_done, nil, nil})
    end
  end

  defp make_request(%Job{} = job, flow_rate) do
    %{total_jobs: total, queue_depth: depth} = EzthrottleLocal.IdempotentStore.counts()
    url = String.to_charlist(job.url)
    metric_headers = [
      {"x-aquifer-total-jobs", to_string(total)},
      {"x-aquifer-queue-depth", to_string(depth)},
      {"x-aquifer-flow-rate", :erlang.float_to_binary(flow_rate * 1.0, [{:decimals, 2}])}
    ]
    headers = headers_to_charlist(Enum.map(job.headers, fn {k, v} -> {k, v} end) ++ metric_headers)

    method = case String.upcase(job.method) do
      "GET" -> :get
      "POST" -> :post
      "PUT" -> :put
      "PATCH" -> :patch
      "DELETE" -> :delete
      _ -> :get
    end

    # :httpc uses {url, headers} for bodyless methods, {url, headers, content_type, body} for body methods
    request = if method in [:post, :put, :patch] do
      body = job.body || ""
      {url, headers, ~c"application/json", body}
    else
      {url, headers}
    end

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        {:ok, %{
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
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  defp parse_rps_header(headers) when is_map(headers) do
    case Map.get(headers, "x-ezthrottle-rps") do
      nil -> nil
      val ->
        case Float.parse(val) do
          {rps, _} -> rps
          :error -> nil
        end
    end
  end
  defp parse_rps_header(_), do: nil

  defp parse_max_concurrent_header(headers) when is_map(headers) do
    case Map.get(headers, "x-ezthrottle-max-concurrent") do
      nil -> nil
      val ->
        case Integer.parse(val) do
          {max, _} -> max
          :error -> nil
        end
    end
  end
  defp parse_max_concurrent_header(_), do: nil

  defp maybe_update_rps(state, nil), do: state
  defp maybe_update_rps(state, rps), do: %{state | rps: max(rps, @min_rps)}

  defp maybe_update_max_concurrent(state, nil), do: state
  defp maybe_update_max_concurrent(state, max), do: %{state | max_concurrent: max}
end
