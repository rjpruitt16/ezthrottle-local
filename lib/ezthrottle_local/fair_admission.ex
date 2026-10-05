defmodule EzthrottleLocal.FairAdmission do
  @moduledoc false

  @default_max_pending_per_upstream 10_000
  @pressure_start 0.70

  def max_pending_per_upstream do
    case Integer.parse(
           System.get_env(
             "EZTHROTTLE_MAX_PENDING_PER_UPSTREAM",
             Integer.to_string(@default_max_pending_per_upstream)
           )
         ) do
      {value, ""} when value >= 0 -> value
      _ -> @default_max_pending_per_upstream
    end
  end

  def decide(queue_pending, total_pending, active_queues, max_backlog, draw \\ :rand.uniform()) do
    active_queues = max(active_queues, 1)
    projected_queue = queue_pending + 1
    projected_total = total_pending + 1

    snapshot = %{
      active_queues: active_queues,
      upstream_backlog: projected_total,
      queue_backlog: projected_queue,
      max_backlog: max_backlog,
      admission_pressure: 0.0,
      rejection_probability: 0.0
    }

    cond do
      max_backlog <= 0 ->
        {:allowed, snapshot}

      projected_total > max_backlog ->
        {:rejected, "upstream_queue",
         %{snapshot | admission_pressure: 1.0, rejection_probability: 1.0}}

      active_queues == 1 ->
        {:allowed, snapshot}

      true ->
        start = @pressure_start * max_backlog
        pressure = clamp((projected_total - start) / (max_backlog - start))
        fair_share = max_backlog / active_queues
        excess = clamp((projected_queue - fair_share) / (max_backlog - fair_share))
        probability = pressure * excess

        snapshot = %{
          snapshot
          | admission_pressure: pressure,
            rejection_probability: probability
        }

        if probability > 0 and clamp(draw) < probability do
          {:rejected, "queue_fair_share", snapshot}
        else
          {:allowed, snapshot}
        end
    end
  end

  def pressure(backlog, max_backlog) when max_backlog > 0 do
    start = @pressure_start * max_backlog
    clamp((backlog - start) / (max_backlog - start))
  end

  def pressure(_backlog, _max_backlog), do: 0.0

  defp clamp(value), do: max(0.0, min(value * 1.0, 1.0))
end
