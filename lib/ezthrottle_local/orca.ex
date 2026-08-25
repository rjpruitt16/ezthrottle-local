defmodule EzthrottleLocal.Orca do
  @moduledoc """
  ORCA (Open Request Cost Aggregation) fallback pacing -- a port of
  Aquifer's orca.go, kept behaviorally identical so both implementations
  pace a backend like vLLM the same way.

  Verified against vLLM's actual current source (not the general ORCA
  gRPC-trailer convention, which vLLM does not use): a backend only
  includes `endpoint-load-metrics` on its response if the request carried
  `endpoint-load-metrics-format` naming the desired format ("TEXT" or
  "JSON"). There is no server-side flag for this in current vLLM.
  """

  @header_name "endpoint-load-metrics"
  @request_header_name "endpoint-load-metrics-format"

  # Different backends report ORCA's KV-cache utilization under different
  # metric names, tried in order -- "kv_cache_usage_perc" is vLLM's name
  # (Prometheus vllm:kv_cache_usage_perc, already a 0-1 fraction).
  # "kv_cache_utilization" is Triton's own ORCA support (src/orca_http.cc,
  # verified directly against source), reporting the same concept under a
  # different name.
  @kv_cache_metric_names ["kv_cache_usage_perc", "kv_cache_utilization"]

  def request_header_name, do: @request_header_name

  @doc """
  Derives a suggested dispatch rate from an ORCA endpoint-load-metrics
  response header, if present and parseable. Returns nil if there's no
  ORCA header, none of @kv_cache_metric_names appear in it, or the
  reported load is low enough that no override is warranted -- callers
  should keep whatever rate is already configured in that case.

  This is a fallback signal, not a primary one -- callers should only
  consult it when the response carried no explicit
  X-Aqueduct-Rps/X-EZThrottle-Rps, which always takes precedence.
  """
  def rps(headers) when is_map(headers) do
    with raw when is_binary(raw) <- Map.get(headers, @header_name),
         metrics when is_map(metrics) <- parse_header(raw),
         util when is_number(util) <- find_kv_cache_metric(metrics) do
      load_to_rps(util)
    else
      _ -> nil
    end
  end

  def rps(_headers), do: nil

  defp find_kv_cache_metric(metrics) do
    Enum.find_value(@kv_cache_metric_names, fn name -> Map.get(metrics, name) end)
  end

  defp parse_header(raw) do
    case String.split(raw, " ", parts: 2) do
      [format, data] ->
        case String.upcase(format) do
          "TEXT" -> parse_text(data)
          "JSON" -> parse_json(data)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Comma-separated "named_metrics.<name>=<value>" pairs, e.g.
  # "named_metrics.kv_cache_usage_perc=0.4, named_metrics.num_requests_waiting=3"
  defp parse_text(data) do
    metrics =
      data
      |> String.split(",")
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [name, val] ->
            name = name |> String.trim() |> String.replace_prefix("named_metrics.", "")

            case Float.parse(String.trim(val)) do
              {v, _} -> Map.put(acc, name, v)
              :error -> acc
            end

          _ ->
            acc
        end
      end)

    if map_size(metrics) == 0, do: nil, else: metrics
  end

  # {"named_metrics": {"<name>": <value>, ...}}
  defp parse_json(data) do
    case Jason.decode(data) do
      {:ok, %{"named_metrics" => metrics}} when is_map(metrics) and map_size(metrics) > 0 ->
        metrics

      _ ->
        nil
    end
  end

  # Maps a 0-1 KV-cache utilization fraction onto a dispatch rate,
  # mirroring the existing pacing-down-gracefully philosophy -- even a
  # fully saturated backend still gets a slow trickle of dispatch, never
  # zero. Identical thresholds to Aquifer's orcaLoadToRps.
  defp load_to_rps(util) when util < 0.70, do: nil
  defp load_to_rps(util) when util < 0.90, do: 2.0
  defp load_to_rps(util) when util < 0.97, do: 0.5
  defp load_to_rps(_util), do: 0.25
end
