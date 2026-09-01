defmodule EzthrottleLocal.RegionAdapter.Fly do
  @moduledoc """
  Polls sibling regions over Fly's private 6PN network to know which are
  currently live, backing /proxy's cross-region redirect
  (EzthrottleLocal.Redirect). Region enumeration is explicit config only
  (EZTHROTTLE_FLY_REGIONS) -- ezthrottle-local never silently polls regions
  a deployer didn't say to use. Direct port of Aquifer's FlyRegionAdapter
  (region_adapter_fly.go).

  Env vars:
    EZTHROTTLE_FLY_REGIONS               - comma-separated region codes;
                                            required for this adapter to do
                                            anything at all (default: unset,
                                            feature off)
    EZTHROTTLE_FLY_POLL_INTERVAL_SECONDS - health-check interval (default 30)
  """

  use GenServer
  @behaviour EzthrottleLocal.RegionAdapter

  @default_poll_interval_seconds 30
  @health_check_timeout_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Comma-separated EZTHROTTLE_FLY_REGIONS, trimmed, empty entries dropped."
  def configured_regions do
    case System.get_env("EZTHROTTLE_FLY_REGIONS") do
      nil ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @impl true
  @doc """
  Returns :ignore when EZTHROTTLE_FLY_REGIONS is unset/empty -- mirrors
  Aquifer's NewFlyRegionAdapter returning nil, so the feature stays off
  unless explicitly configured. application.ex only adds this module to its
  children list when configured_regions/0 is non-empty, so in practice this
  branch is defensive, not the primary gate.
  """
  def init(:ok) do
    case configured_regions() do
      [] ->
        :ignore

      regions ->
        state = %{
          regions: regions,
          self_region: System.get_env("FLY_REGION"),
          app_name: System.get_env("FLY_APP_NAME"),
          port: System.get_env("PORT", "4000"),
          live: []
        }

        # Populate synchronously before returning (bounded by
        # @health_check_timeout_ms since checks run concurrently, not
        # length(regions) * timeout) rather than leaving live_regions()
        # empty for up to a full poll interval right after boot.
        state = do_poll(state)
        Process.send_after(self(), :poll, poll_interval_ms())
        {:ok, state}
    end
  end

  @impl true
  def live_regions, do: safe_call(:live_regions, [])

  @impl true
  def self_region, do: safe_call(:self_region, nil)

  defp safe_call(msg, default) do
    case Process.whereis(__MODULE__) do
      nil -> default
      _pid -> GenServer.call(__MODULE__, msg)
    end
  catch
    :exit, _ -> default
  end

  @impl true
  def handle_call(:live_regions, _from, state), do: {:reply, state.live, state}
  def handle_call(:self_region, _from, state), do: {:reply, state.self_region, state}

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    Process.send_after(self(), :poll, poll_interval_ms())
    {:noreply, state}
  end

  # Checks every configured region concurrently (Task.async_stream -- the
  # direct idiomatic equivalent of Aquifer's sync.WaitGroup+goroutines) and
  # replaces the live list with this cycle's results, ordered nearest-first
  # by the round-trip time this same health check just measured.
  defp do_poll(state) do
    live =
      state.regions
      |> Enum.reject(&(&1 == state.self_region))
      |> Task.async_stream(
        fn region -> {region, region_rtt(region, state.app_name, state.port)} end,
        max_concurrency: max(length(state.regions), 1),
        timeout: @health_check_timeout_ms + 1_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce([], fn
        {:ok, {region, {:ok, rtt_us}}}, acc -> [{region, rtt_us} | acc]
        _, acc -> acc
      end)
      |> Enum.sort_by(fn {_region, rtt_us} -> rtt_us end)
      |> Enum.map(fn {region, _rtt_us} -> region end)

    %{state | live: live}
  end

  # Standing in for a real latency/distance signal -- Fly doesn't publish a
  # region-to-region distance table, so the health check this adapter
  # already has to make to know a region is alive doubles as the only real
  # proximity signal available. Region-prefixed internal DNS form,
  # <region>.$FLY_APP_NAME.internal, confirmed (via Aquifer's own research
  # this session) against Fly's docs to resolve directly to that region's
  # machines over the private 6PN network, bypassing the edge proxy
  # entirely -- no header needed for addressing.
  defp region_rtt(region, app_name, port) do
    url = String.to_charlist("http://#{region}.#{app_name}.internal:#{port}/health")
    started_at = System.monotonic_time(:microsecond)

    case :httpc.request(:get, {url, []}, [{:timeout, @health_check_timeout_ms}], []) do
      {:ok, {{_, 200, _}, _headers, _body}} ->
        {:ok, System.monotonic_time(:microsecond) - started_at}

      _ ->
        :error
    end
  end

  defp poll_interval_ms do
    seconds =
      case System.get_env("EZTHROTTLE_FLY_POLL_INTERVAL_SECONDS") do
        nil -> @default_poll_interval_seconds
        "" -> @default_poll_interval_seconds
        val -> case Integer.parse(val) do
            {n, _} when n > 0 -> n
            _ -> @default_poll_interval_seconds
          end
      end

    seconds * 1_000
  end
end
