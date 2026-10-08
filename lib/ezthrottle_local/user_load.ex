defmodule EzthrottleLocal.UserLoad do
  @moduledoc """
  Per-node counts of each user's accepted-but-unfinished jobs and the webhook
  deliveries owed to them. Backs webhook-backlog admission: a user whose
  undelivered webhooks exceed EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER
  (default 1000; 0 disables) gets 429s with a probability rising to 1 at
  twice the limit, but only while other users are active on the node. A lone
  user is never throttled for it. Mirrors Aquifer's userLoadTracker.
  """
  alias EzthrottleLocal.Job

  @table :ezthrottle_user_load
  @default_limit 1_000

  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  def add(%Job{} = job), do: bump(job, 1)

  def done(%Job{} = job), do: bump(job, -1)

  @doc "Returns :ok or {:rejected, limit, backlog}."
  def webhook_backlog_decision(user_id, draw \\ :rand.uniform()) do
    limit = limit()
    backlog = webhooks(user_id)

    cond do
      limit <= 0 or backlog <= limit -> :ok
      not others_active?(user_id) -> :ok
      draw < min((backlog - limit) / limit, 1.0) -> {:rejected, limit, backlog}
      true -> :ok
    end
  end

  def webhooks(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, _jobs, webhooks}] -> webhooks
      [] -> 0
    end
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  defp bump(%Job{user_id: user_id} = job, incr) do
    pos = if Job.webhook_delivery_job?(job), do: 3, else: 2
    op = if incr < 0, do: {pos, incr, 0, 0}, else: {pos, incr}
    :ets.update_counter(@table, user_id, op, {user_id, 0, 0})
    :ok
  end

  defp others_active?(user_id) do
    :ets.select_count(@table, [
      {{:"$1", :"$2", :"$3"},
       [{:"=/=", :"$1", user_id}, {:orelse, {:>, :"$2", 0}, {:>, :"$3", 0}}], [true]}
    ]) > 0
  end

  defp limit do
    case Integer.parse(System.get_env("EZTHROTTLE_MAX_PENDING_WEBHOOKS_PER_USER", "")) do
      {n, ""} when n >= 0 -> n
      _ -> @default_limit
    end
  end
end
