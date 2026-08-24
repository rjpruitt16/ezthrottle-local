defmodule EzthrottleLocal.DrainFlush do
  @moduledoc """
  Drain mode: opt-in, off by default. When this instance goes completely
  idle (no requests anywhere on the whole node, not just one tenant's
  queue) for EZTHROTTLE_DRAIN_TIMER_SECONDS, it flushes its accumulated
  idempotency ledger to EZTHROTTLE_DRAIN_WEBHOOK_URL and, only on
  confirmed delivery, clears local state (IdempotentStore.clear_ledger/0)
  -- making the instance safe to hand off to a different tenant. The
  consuming service on the other end (deciding which tenant gets a freed
  instance next, and retaining the ledger long-term) is not part of this
  project -- see README.md "Drain mode" for the webhook contract an
  operator builds against.

  Env vars:
    EZTHROTTLE_DRAIN_ENABLED        - the real gate (default: false)
    EZTHROTTLE_DRAIN_TIMER_SECONDS  - how long idle before flushing (default: 45)
    EZTHROTTLE_DRAIN_WEBHOOK_URL    - required if enabled; enabled without
                                       this configured is treated as
                                       disabled (logged), never a flush
                                       attempt with nowhere to send it

  Disabled by default means exactly that: EzthrottleLocal.AccountQueueRegistry
  only schedules the periodic idle-check message when enabled?/0 is true at
  startup -- not a recurring check that runs and no-ops.
  """

  require Logger

  alias EzthrottleLocal.{IdempotentStore, Metrics, Webhook}

  @default_timer_seconds 45

  @doc """
  Whether drain mode is actually active -- checks both the enable flag and
  that a webhook destination is configured, logging a warning (once, since
  callers only invoke this at startup) if enabled but misconfigured.
  """
  def enabled? do
    flag = env_bool("EZTHROTTLE_DRAIN_ENABLED", false)

    cond do
      not flag ->
        false

      webhook_url() in [nil, ""] ->
        Logger.warning(
          "[Drain] EZTHROTTLE_DRAIN_ENABLED is true but EZTHROTTLE_DRAIN_WEBHOOK_URL is not set — drain mode disabled, nowhere to send the ledger"
        )

        false

      true ->
        true
    end
  end

  def timer_seconds, do: env_int("EZTHROTTLE_DRAIN_TIMER_SECONDS", @default_timer_seconds)
  def webhook_url, do: System.get_env("EZTHROTTLE_DRAIN_WEBHOOK_URL")

  @doc """
  Enumerates the ledger, delivers it, and only clears local state on
  confirmed delivery. Returns true when this idle period is "handled" (a
  successful flush, or nothing to flush at all) and false when the caller
  should retry on the next tick -- safe to retry, since nothing was
  cleared on failure.
  """
  def attempt do
    case IdempotentStore.list_ledger() do
      [] ->
        true

      entries ->
        payload = %{
          event: "instance_idle",
          flushed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          ledger: entries
        }

        case Webhook.deliver(webhook_url(), payload) do
          :ok ->
            IdempotentStore.clear_ledger()
            Metrics.drain_flush_succeeded(webhook_url(), length(entries))
            Logger.info("[Drain] flushed and cleared ledger (#{length(entries)} entries)")
            true

          :error ->
            Metrics.drain_flush_failed(webhook_url(), length(entries))

            Logger.error(
              "[Drain] failed to deliver ledger flush (#{length(entries)} entries) after retries — not clearing, will retry"
            )

            false
        end
    end
  end

  # ---- Private ----

  defp env_bool(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> String.downcase(val) in ["1", "true", "yes"]
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> default
        end
    end
  end
end
