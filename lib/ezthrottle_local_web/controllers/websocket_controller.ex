defmodule EzthrottleLocalWeb.WebSocketController do
  @moduledoc false

  use EzthrottleLocalWeb, :controller

  plug EzthrottleLocalWeb.NodeDraining

  alias EzthrottleLocal.{
    WebSocketConfig,
    WebSocketProtocol,
    WebSocketQueue,
    WebSocketStore
  }

  def connect(conn, params) do
    config = WebSocketConfig.load()
    session_id = params["session_id"]
    cursor = params["after"] || "0-0"
    upstream_url = header(conn, WebSocketProtocol.upstream_header())

    with :ok <- require_enabled(config),
         :ok <- require_upgrade(conn),
         :ok <- require_subprotocol(conn),
         :ok <- require_session(session_id),
         :ok <- validate_cursor(cursor),
         :ok <- validate_upstream(upstream_url),
         :ok <- WebSocketStore.check_cursor(session_id, cursor),
         {:ok, client_token} <- WebSocketQueue.reserve_client() do
      state = %{
        config: config,
        client_token: client_token,
        session_id: session_id,
        cursor: cursor,
        upstream_url: upstream_url,
        upstream_headers: forwarded_headers(conn, session_id)
      }

      upgrade(conn, state)
    else
      {:error, :disabled} ->
        json_error(conn, 404, "websocket proxy is disabled")

      {:error, :upgrade_required} ->
        json_error(conn, 426, "websocket upgrade required")

      {:error, :subprotocol} ->
        json_error(conn, 400, "Sec-WebSocket-Protocol must include aqueduct.v1")

      {:error, :session_required} ->
        json_error(conn, 400, "session_id is required")

      {:error, :invalid_cursor} ->
        json_error(conn, 400, "after must be a stream id")

      {:error, :invalid_upstream} ->
        json_error(conn, 400, "X-Aqueduct-Upstream-URL must be an absolute ws:// or wss:// URL")

      {:error, :upstream_not_allowed} ->
        json_error(
          conn,
          400,
          "websocket upstream domain is not in EZTHROTTLE_ALLOWED_URL_DOMAINS"
        )

      {:error, :replay_gap} ->
        json_error(conn, 409, "websocket replay cursor is older than retained history")

      {:error, :client_limit} ->
        retry_error(conn, 429, "websocket client connection limit reached")

      {:error, reason} ->
        retry_error(conn, 503, "websocket event store unavailable: #{inspect(reason)}")
    end
  end

  defp upgrade(conn, state) do
    conn
    |> put_resp_header("sec-websocket-protocol", WebSocketProtocol.subprotocol())
    |> WebSockAdapter.upgrade(EzthrottleLocalWeb.WebSocket, state,
      timeout: :infinity,
      max_frame_size: state.config.max_message_bytes
    )
    |> halt()
  rescue
    error in WebSockAdapter.UpgradeError ->
      WebSocketQueue.release_client(state.client_token)
      json_error(conn, 426, Exception.message(error))
  end

  defp require_enabled(%{enabled: true}), do: :ok
  defp require_enabled(_config), do: {:error, :disabled}

  defp require_upgrade(conn) do
    if String.downcase(header(conn, "upgrade")) == "websocket",
      do: :ok,
      else: {:error, :upgrade_required}
  end

  defp require_subprotocol(conn) do
    protocols =
      conn
      |> header("sec-websocket-protocol")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    if WebSocketProtocol.subprotocol() in protocols, do: :ok, else: {:error, :subprotocol}
  end

  defp require_session(value) when is_binary(value) and value != "", do: :ok
  defp require_session(_value), do: {:error, :session_required}

  defp validate_cursor(cursor) do
    case WebSocketStore.parse_cursor(cursor) do
      {:ok, _parsed} -> :ok
      {:error, _reason} -> {:error, :invalid_cursor}
    end
  end

  defp validate_upstream(raw) when is_binary(raw) do
    case URI.parse(raw) do
      %URI{scheme: scheme, host: host} when scheme in ["ws", "wss"] and is_binary(host) ->
        if allowed_host?(host), do: :ok, else: {:error, :upstream_not_allowed}

      _ ->
        {:error, :invalid_upstream}
    end
  end

  defp validate_upstream(_raw), do: {:error, :invalid_upstream}

  defp allowed_host?(host) do
    case System.get_env("EZTHROTTLE_ALLOWED_URL_DOMAINS", "") do
      "" ->
        true

      allowlist ->
        Enum.any?(String.split(allowlist, ","), fn allowed ->
          allowed = String.trim(allowed)
          allowed != "" and (host == allowed or String.ends_with?(host, "." <> allowed))
        end)
    end
  end

  defp forwarded_headers(conn, session_id) do
    blocked = [
      "connection",
      "upgrade",
      "sec-websocket-key",
      "sec-websocket-version",
      "sec-websocket-extensions",
      "sec-websocket-protocol",
      "host"
    ]

    headers =
      Enum.reject(conn.req_headers, fn {name, _value} ->
        name in blocked or String.starts_with?(name, "x-aqueduct-") or
          String.starts_with?(name, "x-aquifer-")
      end)

    [{"X-Aqueduct-Session-ID", session_id} | headers]
  end

  defp header(conn, name) do
    conn
    |> get_req_header(String.downcase(name))
    |> List.first()
    |> to_string()
  end

  defp retry_error(conn, status, message) do
    conn
    |> put_resp_header("retry-after", "1")
    |> json_error(status, message)
  end

  defp json_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
    |> halt()
  end
end
