defmodule EzthrottleLocal.Redirect do
  @moduledoc """
  Cross-region /proxy redirect on partial Fly.io outages -- direct port of
  Aquifer's region_redirect.go, adapted to Elixir/OTP idioms. Called from
  EzthrottleLocal.Proxy's local-fallback points, never for a request
  already inside someone else's redirect tour. Tours other known-live
  regions directly over Fly's private network before this instance falls
  back to its own local queue.

  Env vars:
    EZTHROTTLE_REDIRECT_GATE_COOLDOWN_SECONDS       - internal probe-retry
                                                       throttling only, not
                                                       what's told to the
                                                       caller (default 500)
    EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS - Retry-After told to
                                                       the caller on total
                                                       exhaustion (default
                                                       900 -- a real
                                                       regional outage, not
                                                       a transient blip)
  """

  alias EzthrottleLocal.Job
  alias EzthrottleLocal.RegionAdapter

  require Logger

  @default_gate_cooldown_seconds 500
  @default_exhausted_retry_after_seconds 900
  @direct_only_timeout_ms 3_000
  @gate_agent __MODULE__.Gate
  @self_machine_id_key {__MODULE__, :self_machine_id}

  @doc "Retry-After told to the caller when redirect is configured but exhausted."
  def exhausted_retry_after_seconds do
    env_int("EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS", @default_exhausted_retry_after_seconds)
  end

  defp gate_cooldown_ms do
    env_int("EZTHROTTLE_REDIRECT_GATE_COOLDOWN_SECONDS", @default_gate_cooldown_seconds) * 1_000
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> case Integer.parse(val) do
          {n, _} when n > 0 -> n
          _ -> default
        end
    end
  end

  # -- Redirect gate: separate from the per-domain breaker, per-instance,
  # no fleet coordination. Answers "is attempting cross-region redirect
  # itself worth trying right now" -- trips after a tour finds no
  # reachable alternate region at all. While tripped, callers get
  # :exhausted immediately without a real tour. Only started
  # (application.ex) alongside RegionAdapter.Fly.

  def gate_child_spec do
    %{
      id: @gate_agent,
      start: {Agent, :start_link, [fn -> nil end, [name: @gate_agent]]}
    }
  end

  @doc "Public so tests can exercise the gate in isolation (start it via gate_child_spec/0, trip it, assert open/cooldown) -- the same isolated-unit coverage Aquifer's own redirectGate struct gets, adapted to a named Agent process instead of a freestanding struct."
  def gate_open? do
    case Process.whereis(@gate_agent) do
      nil -> false
      _pid -> case Agent.get(@gate_agent, & &1) do
          nil -> false
          until -> System.monotonic_time(:millisecond) < until
        end
    end
  catch
    :exit, _ -> false
  end

  @doc "cooldown_ms defaults to the configured EZTHROTTLE_REDIRECT_GATE_COOLDOWN_SECONDS; accepts an explicit override so tests can trip the gate for a short, fast-to-assert-on duration instead of waiting out a real 500s+ default -- mirrors Aquifer's redirectGate.Trip(cooldown) taking an explicit duration."
  def gate_trip(cooldown_ms \\ gate_cooldown_ms()) do
    case Process.whereis(@gate_agent) do
      nil -> :ok
      _pid -> Agent.update(@gate_agent, fn _ -> System.monotonic_time(:millisecond) + cooldown_ms end)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Identifies this instance for origin_machine_id purposes only -- not a security boundary, just a way for a receiving instance to know a request already belongs to someone else's redirect tour. FLY_MACHINE_ID on Fly; hostname, then a random id, as local-dev fallbacks. Cached via :persistent_term -- compute once, read cheaply forever, the idiomatic match for Go's sync.Once."
  def self_machine_id do
    case :persistent_term.get(@self_machine_id_key, nil) do
      nil ->
        id = compute_self_machine_id()
        :persistent_term.put(@self_machine_id_key, id)
        id

      id ->
        id
    end
  end

  defp compute_self_machine_id do
    case System.get_env("FLY_MACHINE_ID") do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case :inet.gethostname() do
          {:ok, host} when host != ~c"" -> to_string(host)
          _ -> :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        end
    end
  end

  @doc """
  Rendezvous/highest-random-weight hashing -- deterministically selects one
  candidate for a given key. Two independent callers computing this over
  the same candidates and key always get the same answer, with no
  coordination between them. Used to choose which region gets first crack
  at owning a job's durable queue if no region can dispatch it directly.
  """
  def rendezvous_pick([], _key), do: nil

  def rendezvous_pick(candidates, key) do
    Enum.max_by(candidates, &rendezvous_score(&1, key))
  end

  defp rendezvous_score(candidate, key) do
    :crypto.hash(:sha256, candidate <> ":" <> key) |> Base.encode16(case: :lower)
  end

  @doc """
  Builds the tour order for a job: live regions minus self and anything
  already visited, with the rendezvous-preferred region always first (see
  rendezvous_pick/2, for cross-origin collision avoidance) and everything
  else in the order live_regions/0 already provided it in -- nearest-first
  by measured health-check RTT for RegionAdapter.Fly, the only real
  proximity signal available since Fly doesn't publish a region distance
  table.
  """
  def ordered_redirect_candidates(live, visited, self_region, idempotent_key) do
    visited_set = MapSet.new(visited)

    eligible =
      Enum.reject(live, fn region -> region == self_region or MapSet.member?(visited_set, region) end)

    case eligible do
      [] ->
        []

      _ ->
        preferred = rendezvous_pick(eligible, idempotent_key)
        rest = Enum.reject(eligible, &(&1 == preferred))
        [preferred | rest]
    end
  end

  @doc """
  Mirrors Aquifer's attemptRedirect. Returns :not_applicable (feature not
  configured, or this request already belongs to someone else's tour --
  caller proceeds with its own existing local-fallback behavior, completely
  unchanged), {:succeeded, outcome}, or :exhausted (feature IS configured
  but couldn't help -- caller must hard-error, never a silent local-queue
  fallback).
  """
  def attempt_redirect(%Job{origin_machine_id: id}, _account_queue_header) when is_binary(id) do
    :not_applicable
  end

  def attempt_redirect(%Job{} = job, account_queue_header) do
    if configured?() do
      do_attempt_redirect(job, account_queue_header)
    else
      :not_applicable
    end
  end

  defp configured? do
    Application.get_env(:ezthrottle_local, :region_adapter) not in [nil, EzthrottleLocal.RegionAdapter.Noop]
  end

  defp do_attempt_redirect(job, account_queue_header) do
    if gate_open?() do
      :exhausted
    else
      self_region = RegionAdapter.self_region()
      live = RegionAdapter.live_regions()

      job = %{job | origin_machine_id: self_machine_id(), origin_region: self_region}

      candidates = ordered_redirect_candidates(live, job.visited_regions, self_region, job.idempotent_key)

      case candidates do
        [] ->
          :exhausted

        _ ->
          Logger.info("[redirect] job #{job.id}: origin=#{self_region} trying candidates #{inspect(candidates)}")
          tour(job, candidates, account_queue_header)
      end
    end
  end

  # Phase 1: try every live candidate for a fast direct success only --
  # none are allowed to commit to their own local queue yet (direct_only),
  # so trying several in sequence can never leave the job durably
  # committed in more than one place.
  defp tour(job, candidates, account_queue_header) do
    {result, any_reached} =
      Enum.reduce_while(candidates, {nil, false}, fn region, {_result, any_reached} ->
        case hop(job, region, account_queue_header, true, @direct_only_timeout_ms) do
          {:direct, status, headers, body} ->
            Logger.info("[redirect] job #{job.id}: #{region} succeeded directly")
            {:halt, {{:succeeded, {:direct, status, headers, region}, body}, true}}

          {:reached, :rejected} ->
            {:cont, {nil, true}}

          :unreachable ->
            {:cont, {nil, any_reached}}
        end
      end)

    case result do
      {:succeeded, {:direct, status, headers, region}, body} ->
        {:succeeded, {:direct, status, headers, body, region}}

      nil ->
        phase_2(job, candidates, account_queue_header, any_reached)
    end
  end

  # Phase 2: nobody could succeed directly -- make exactly one committing
  # call, to the same deterministically-chosen candidate every origin
  # computing this over the same inputs would also pick first (hd(candidates)
  # by construction -- see ordered_redirect_candidates/4). Prevents the
  # double-commit correctness gap: without this, trying several candidates
  # in sequence with direct_only false could leave the SAME job durably
  # committed in more than one place.
  defp phase_2(job, candidates, account_queue_header, any_reached_in_phase_1) do
    final = hd(candidates)

    case hop(job, final, account_queue_header, false, :infinity) do
      {:direct, status, headers, body} ->
        Logger.info("[redirect] job #{job.id}: #{final} accepted it into its own queue (direct)")
        {:succeeded, {:direct, status, headers, body, final}}

      {:relay, request_id} ->
        Logger.info("[redirect] job #{job.id}: #{final} accepted it into its own queue")
        {:succeeded, {:relay, request_id, final}}

      {:reached, :rejected} ->
        maybe_trip_gate(job.id, true)
        :exhausted

      :unreachable ->
        maybe_trip_gate(job.id, any_reached_in_phase_1)
        :exhausted
    end
  end

  defp maybe_trip_gate(job_id, any_reached) do
    if any_reached do
      Logger.info("[redirect] job #{job_id}: every candidate tried, none could help -- gating redirect")
      gate_trip()
    end
  end

  # Dials one candidate region directly over Fly's private 6PN network
  # (<region>.$FLY_APP_NAME.internal). direct_only true is a bounded,
  # synchronous, fully-buffered request -- it can never turn into a stream
  # by construction. direct_only false streams the response
  # (:httpc stream: :self) since it might become a live SSE relay; a small
  # buffered response arrives through the same mechanism, just accumulated
  # into {:direct, ...} instead of relayed live.
  defp hop(job, region, account_queue_header, direct_only, timeout_ms) do
    hop_job = %{
      job
      | visited_regions: job.visited_regions ++ [region],
        reroute_count: job.reroute_count + 1,
        direct_only: direct_only
    }

    body =
      Jason.encode!(%{
        user_id: hop_job.user_id,
        idempotent_key: hop_job.idempotent_key,
        url: hop_job.url,
        pool_id: hop_job.pool_id,
        method: hop_job.method,
        headers: hop_job.headers,
        body: hop_job.body,
        webhook_url: hop_job.webhook_url,
        origin_machine_id: hop_job.origin_machine_id,
        origin_region: hop_job.origin_region,
        visited_regions: hop_job.visited_regions,
        reroute_count: hop_job.reroute_count,
        direct_only: hop_job.direct_only
      })

    url = String.to_charlist(redirect_target_url(region))

    headers =
      [{~c"content-type", ~c"application/json"}] ++
        if account_queue_header not in [nil, ""] do
          [{~c"x-aquifer-account-queue", String.to_charlist(account_queue_header)}]
        else
          []
        end

    if direct_only do
      case :httpc.request(:post, {url, headers, ~c"application/json", body}, [{:timeout, timeout_ms}], []) do
        {:ok, {{_, status, _}, resp_headers, resp_body}} when status >= 200 and status < 300 ->
          {:direct, status, charlist_headers_to_map(resp_headers), to_string(resp_body)}

        {:ok, {{_, _status, _}, _resp_headers, _resp_body}} ->
          {:reached, :rejected}

        {:error, _reason} ->
          :unreachable
      end
    else
      stream_hop(url, headers, body)
    end
  end

  defp stream_hop(url, headers, body) do
    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [],
           [sync: false, stream: :self]
         ) do
      {:ok, request_id} ->
        await_stream_start(request_id)

      {:error, _reason} ->
        :unreachable
    end
  end

  defp await_stream_start(request_id) do
    receive do
      {:http, {^request_id, :stream_start, resp_headers}} ->
        headers_map = charlist_headers_to_map(resp_headers)

        if String.starts_with?(Map.get(headers_map, "content-type", ""), "text/event-stream") do
          {:relay, request_id}
        else
          accumulate_direct(request_id, headers_map, 200, [])
        end

      {:http, {^request_id, {{_, status, _}, resp_headers, resp_body}}} ->
        # Non-streaming async response (target answered without chunking at
        # all, e.g. a plain small JSON rejection) -- httpc can deliver this
        # shape too depending on the target's own response framing.
        if status >= 200 and status < 300 do
          {:direct, status, charlist_headers_to_map(resp_headers), to_string(resp_body)}
        else
          {:reached, :rejected}
        end

      {:http, {^request_id, {:error, _reason}}} ->
        :unreachable
    after
      10_000 -> :unreachable
    end
  end

  defp accumulate_direct(request_id, headers_map, status, acc) do
    receive do
      {:http, {^request_id, :stream, chunk}} ->
        accumulate_direct(request_id, headers_map, status, [chunk | acc])

      {:http, {^request_id, :stream_end, _final_headers}} ->
        body = acc |> Enum.reverse() |> IO.iodata_to_binary()

        if status >= 200 and status < 300 do
          {:direct, status, headers_map, body}
        else
          {:reached, :rejected}
        end
    after
      10_000 -> :unreachable
    end
  end

  defp charlist_headers_to_map(headers) do
    Enum.reduce(headers, %{}, fn {k, v}, acc ->
      Map.put(acc, k |> to_string() |> String.downcase(), to_string(v))
    end)
  end

  @doc "Overridable in tests (real .internal DNS can't resolve in a unit test environment) via Application env :redirect_target_url_builder -- same 'injectable for testability, real by default' pattern as the rest of this codebase."
  def redirect_target_url(region) do
    builder =
      Application.get_env(:ezthrottle_local, :redirect_target_url_builder, &default_redirect_target_url/1)

    builder.(region)
  end

  defp default_redirect_target_url(region) do
    app_name = System.get_env("FLY_APP_NAME")
    port = System.get_env("PORT", "4000")
    "http://#{region}.#{app_name}.internal:#{port}/proxy"
  end
end
