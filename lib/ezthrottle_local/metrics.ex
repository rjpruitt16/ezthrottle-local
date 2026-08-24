defmodule EzthrottleLocal.Metrics do
  @moduledoc """
  Pluggable metrics adapter entrypoint.

  Configure `:metrics_adapter` to route lifecycle events to a custom module.
  """

  @type user_id :: String.t()
  @type upstream :: String.t()
  @type url :: String.t()

  @callback job_queued(user_id(), upstream()) :: :ok
  @callback job_dispatched(user_id(), upstream()) :: :ok
  @callback job_completed(user_id(), upstream(), duration_ms :: integer()) :: :ok
  @callback job_failed(user_id(), upstream(), reason :: String.t()) :: :ok
  @callback webhook_delivered(url(), attempt :: integer()) :: :ok
  @callback webhook_failed(url(), attempts :: integer()) :: :ok
  @callback queue_depth(upstream(), depth :: integer()) :: :ok
  @callback flow_rate(upstream(), rps :: float()) :: :ok
  # Only ever fire when drain mode is enabled (see EzthrottleLocal.DrainFlush) --
  # unreached on a deployment that never turns it on.
  @callback drain_flush_succeeded(instance_key :: String.t(), ledger_size :: integer()) :: :ok
  @callback drain_flush_failed(instance_key :: String.t(), ledger_size :: integer()) :: :ok

  def job_queued(user_id, upstream), do: call(:job_queued, [user_id, upstream])
  def job_dispatched(user_id, upstream), do: call(:job_dispatched, [user_id, upstream])

  def job_completed(user_id, upstream, duration_ms),
    do: call(:job_completed, [user_id, upstream, duration_ms])

  def job_failed(user_id, upstream, reason), do: call(:job_failed, [user_id, upstream, reason])
  def webhook_delivered(url, attempt), do: call(:webhook_delivered, [url, attempt])
  def webhook_failed(url, attempts), do: call(:webhook_failed, [url, attempts])
  def queue_depth(upstream, depth), do: call(:queue_depth, [upstream, depth])
  def flow_rate(upstream, rps), do: call(:flow_rate, [upstream, rps])

  def drain_flush_succeeded(instance_key, ledger_size),
    do: call(:drain_flush_succeeded, [instance_key, ledger_size])

  def drain_flush_failed(instance_key, ledger_size),
    do: call(:drain_flush_failed, [instance_key, ledger_size])

  def upstream(raw_url) do
    case URI.parse(raw_url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        raw_url
    end
  end

  defp call(event, args) do
    adapter =
      Application.get_env(:ezthrottle_local, :metrics_adapter, EzthrottleLocal.Metrics.Noop)

    apply(adapter, event, args)
  rescue
    _ -> :ok
  end
end
