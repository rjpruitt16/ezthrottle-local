defmodule EzthrottleLocal.Webhook do
  @moduledoc """
  Fire and forget webhook delivery.
  Best effort — no retry on failure.
  Use EZThrottle Cloud for guaranteed delivery.
  """

  require Logger

  @doc """
  Deliver a webhook payload to the given URL.
  Runs in the calling process — wrap in Task.start/1 for async delivery.
  """
  def deliver(url, payload) do
    body = Jason.encode!(payload)

    case :httpc.request(
      :post,
      {String.to_charlist(url), [], ~c"application/json", String.to_charlist(body)},
      [{:timeout, 5_000}],
      []
    ) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _headers, _body}} ->
        Logger.warning("[Webhook] Non-2xx response #{status} for #{url}")
        :error

      {:error, reason} ->
        Logger.warning("[Webhook] Failed to deliver to #{url}: #{inspect(reason)}")
        :error
    end
  end
end
