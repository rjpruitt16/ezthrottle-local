defmodule EzthrottleLocal.Webhook do
  @moduledoc """
  Synchronous webhook delivery with exponential backoff and optional L8
  signed headers. Retries up to @max_retries times on non-2xx or
  connection error.

  Used only by drain mode's ledger-flush webhook (EzthrottleLocal.DrainFlush),
  where clearing the local idempotency ledger must wait on confirmed
  delivery. Regular per-job completion/failure webhooks go through
  AccountQueueRegistry.enqueue_webhook/4 instead, which paces delivery
  through the same account-queue machinery as forward dispatch rather than
  firing immediately from here.
  """

  require Logger

  @max_retries 4

  def deliver(url, payload, attempt \\ 0)

  def deliver(url, payload, attempt) when attempt < @max_retries do
    body = Jason.encode!(payload)
    EzthrottleLocal.L8.ensure_trust(url)
    l8_headers = l8_headers_for(url, body)

    case do_post(url, body, l8_headers) do
      {:ok, status} when status in 200..299 ->
        EzthrottleLocal.Metrics.webhook_delivered(url, attempt + 1)
        :ok

      {:ok, status} ->
        backoff = backoff_ms(attempt)

        Logger.warning(
          "[Webhook] #{status} from #{url}, retry #{attempt + 1}/#{@max_retries} in #{backoff}ms"
        )

        Process.sleep(backoff)
        deliver(url, payload, attempt + 1)

      {:error, reason} ->
        backoff = backoff_ms(attempt)

        Logger.warning(
          "[Webhook] Error delivering to #{url}, retry #{attempt + 1}/#{@max_retries} in #{backoff}ms: #{inspect(reason)}"
        )

        Process.sleep(backoff)
        deliver(url, payload, attempt + 1)
    end
  end

  def deliver(url, payload, _attempt) do
    body = Jason.encode!(payload)
    EzthrottleLocal.L8.ensure_trust(url)
    l8_headers = l8_headers_for(url, body)

    case do_post(url, body, l8_headers) do
      {:ok, status} when status in 200..299 ->
        EzthrottleLocal.Metrics.webhook_delivered(url, @max_retries + 1)
        :ok

      {:ok, status} ->
        Logger.warning(
          "[Webhook] Giving up after #{@max_retries} retries, last status #{status} for #{url}"
        )

        EzthrottleLocal.Metrics.webhook_failed(url, @max_retries + 1)
        :error

      {:error, reason} ->
        Logger.warning(
          "[Webhook] Giving up after #{@max_retries} retries for #{url}: #{inspect(reason)}"
        )

        EzthrottleLocal.Metrics.webhook_failed(url, @max_retries + 1)
        :error
    end
  end

  defp do_post(url, body, extra_headers) do
    headers =
      Enum.map(extra_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(body)},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp l8_headers_for(url, body) do
    if EzthrottleLocal.L8.is_trusted?(url) do
      EzthrottleLocal.L8.sign_headers(body)
    else
      %{}
    end
  end

  defp backoff_ms(attempt), do: trunc(:math.pow(2, attempt) * 1_000)
end
