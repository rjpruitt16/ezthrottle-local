defmodule EzthrottleLocal.Metrics.Noop do
  @moduledoc false

  @behaviour EzthrottleLocal.Metrics

  @impl true
  def job_queued(_user_id, _upstream), do: :ok

  @impl true
  def job_dispatched(_user_id, _upstream), do: :ok

  @impl true
  def job_completed(_user_id, _upstream, _duration_ms), do: :ok

  @impl true
  def job_failed(_user_id, _upstream, _reason), do: :ok

  @impl true
  def webhook_delivered(_url, _attempt), do: :ok

  @impl true
  def webhook_failed(_url, _attempts), do: :ok

  @impl true
  def queue_depth(_upstream, _depth), do: :ok

  @impl true
  def flow_rate(_upstream, _rps), do: :ok
end
