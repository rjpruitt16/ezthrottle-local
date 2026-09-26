defmodule EzthrottleLocal.WebSocketProtocol do
  @moduledoc false

  @subprotocol "aqueduct.v1"
  @upstream_header "x-aqueduct-upstream-url"

  def subprotocol, do: @subprotocol
  def upstream_header, do: @upstream_header

  def decode_client(raw) when is_binary(raw) do
    with {:ok, message} <- Jason.decode(raw),
         true <-
           message["type"] == "command" || {:error, "clients may only send command messages"},
         true <- present?(message["message_id"]) || {:error, "message_id is required"},
         true <- Map.has_key?(message, "payload") || {:error, "payload is required"} do
      {:ok, application_fields(message)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "invalid json"}
      {:error, reason} -> {:error, reason}
      false -> {:error, "invalid aqueduct websocket message"}
    end
  end

  def decode_backend(raw) when is_binary(raw) do
    with {:ok, message} <- Jason.decode(raw) do
      validate_backend(message)
    else
      {:error, %Jason.DecodeError{}} -> {:error, "invalid json"}
    end
  end

  def encode(message), do: Jason.encode!(message)

  defp validate_backend(%{"type" => type} = message) when type in ["ack", "event"] do
    cond do
      not present?(message["message_id"]) ->
        {:error, "#{type} message_id is required"}

      type == "event" and not Map.has_key?(message, "payload") ->
        {:error, "event payload is required"}

      true ->
        {:ok, application_fields(message)}
    end
  end

  defp validate_backend(%{"type" => "aqueduct.capacity"} = message) do
    max_connections = message["max_connections"]
    connect_rps = message["connect_rps"]

    cond do
      is_nil(max_connections) and is_nil(connect_rps) ->
        {:error, "capacity message must set max_connections or connect_rps"}

      not is_nil(max_connections) and (not is_integer(max_connections) or max_connections <= 0) ->
        {:error, "max_connections must be positive"}

      not is_nil(connect_rps) and (not is_number(connect_rps) or connect_rps <= 0) ->
        {:error, "connect_rps must be positive"}

      true ->
        {:ok, application_fields(message)}
    end
  end

  defp validate_backend(%{"type" => type}),
    do: {:error, "unsupported backend message type #{inspect(type)}"}

  defp validate_backend(_), do: {:error, "unsupported backend message type"}

  defp application_fields(message) do
    Map.take(message, [
      "type",
      "state",
      "message_id",
      "caused_by",
      "stream_id",
      "payload",
      "reason",
      "position",
      "generation",
      "retry_after_ms",
      "max_connections",
      "connect_rps"
    ])
  end

  defp present?(value), do: is_binary(value) and value != ""
end
