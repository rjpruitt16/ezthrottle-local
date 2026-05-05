defmodule EzthrottleLocal.Webhook do
  @moduledoc """
  Webhook delivery with exponential backoff.
  Retries up to @max_retries times on non-2xx or connection error.
  Use EZThrottle Cloud for guaranteed delivery with persistence.
  """

  require Logger

  @max_retries 4

  def deliver(url, payload, attempt \\ 0)

  def deliver(url, payload, attempt) when attempt < @max_retries do
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
        backoff = backoff_ms(attempt)
        Logger.warning("[Webhook] #{status} from #{url}, retry #{attempt + 1}/#{@max_retries} in #{backoff}ms")
        Process.sleep(backoff)
        deliver(url, payload, attempt + 1)

      {:error, reason} ->
        backoff = backoff_ms(attempt)
        Logger.warning("[Webhook] Error delivering to #{url}, retry #{attempt + 1}/#{@max_retries} in #{backoff}ms: #{inspect(reason)}")
        Process.sleep(backoff)
        deliver(url, payload, attempt + 1)
    end
  end

  def deliver(url, payload, _attempt) do
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
        Logger.warning("[Webhook] Giving up after #{@max_retries} retries, last status #{status} for #{url}")
        :error

      {:error, reason} ->
        Logger.warning("[Webhook] Giving up after #{@max_retries} retries for #{url}: #{inspect(reason)}")
        :error
    end
  end

  defp backoff_ms(attempt), do: trunc(:math.pow(2, attempt) * 1_000)
end
