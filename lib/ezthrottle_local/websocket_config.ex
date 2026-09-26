defmodule EzthrottleLocal.WebSocketConfig do
  @moduledoc false

  defstruct enabled: true,
            stream_max_events: 10_000,
            stream_ttl_ms: 86_400_000,
            read_batch: 100,
            max_message_bytes: 1_048_576,
            handshake_timeout_ms: 10_000,
            reconnect_max_ms: 30_000,
            idle_timeout_ms: 30_000,
            max_clients: 1_000,
            max_upstreams: 1_000,
            max_waiting: 1_000,
            connect_rps: 20.0,
            slow_start_rps: 1.0

  def load do
    connect_rps = positive_float("EZTHROTTLE_WS_CONNECT_RPS", 20.0)

    %__MODULE__{
      enabled: enabled?(),
      stream_max_events: positive_integer("EZTHROTTLE_WS_STREAM_MAX_EVENTS", 10_000),
      stream_ttl_ms: positive_integer("EZTHROTTLE_WS_STREAM_TTL_SECONDS", 86_400) * 1_000,
      read_batch: positive_integer("EZTHROTTLE_WS_READ_BATCH", 100),
      max_message_bytes: positive_integer("EZTHROTTLE_WS_MAX_MESSAGE_BYTES", 1_048_576),
      handshake_timeout_ms:
        positive_integer("EZTHROTTLE_WS_HANDSHAKE_TIMEOUT_SECONDS", 10) * 1_000,
      reconnect_max_ms: positive_integer("EZTHROTTLE_WS_RECONNECT_MAX_SECONDS", 30) * 1_000,
      idle_timeout_ms: positive_integer("EZTHROTTLE_WS_IDLE_TIMEOUT_SECONDS", 30) * 1_000,
      max_clients: positive_integer("EZTHROTTLE_WS_MAX_CLIENT_CONNECTIONS", 1_000),
      max_upstreams: positive_integer("EZTHROTTLE_WS_MAX_UPSTREAM_CONNECTIONS", 1_000),
      max_waiting: positive_integer("EZTHROTTLE_WS_MAX_WAITING_CONNECTIONS", 1_000),
      connect_rps: connect_rps,
      slow_start_rps:
        "EZTHROTTLE_WS_SLOW_START_RPS"
        |> positive_float(1.0)
        |> min(connect_rps)
    }
  end

  defp enabled? do
    System.get_env("EZTHROTTLE_WS_ENABLED", "true")
    |> String.downcase()
    |> Kernel.!=("false")
  end

  defp positive_integer(name, fallback) do
    case Integer.parse(System.get_env(name, "")) do
      {value, ""} when value > 0 -> value
      _ -> fallback
    end
  end

  defp positive_float(name, fallback) do
    case Float.parse(System.get_env(name, "")) do
      {value, ""} when value > 0 -> value
      _ -> fallback
    end
  end
end
