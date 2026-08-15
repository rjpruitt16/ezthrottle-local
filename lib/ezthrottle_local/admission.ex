defmodule EzthrottleLocal.Admission do
  @moduledoc """
  Memory/DB-size/body-size ceilings that protect this instance from the
  traffic it's meant to be absorbing, mirroring Aquifer's admission
  control. Body-size and DB-size limits default on, sized off the
  infrastructure this project is actually benchmarked against (a single
  512MB Fly.io instance with a 1GB volume — see benchmark.md); an
  explicit 0 still disables a given check. Memory has no safe
  one-size-fits-all default (it depends on the deployment's own memory
  budget, not benchmarked disk usage), so it stays disabled unless set
  explicitly — start_link/1 logs a warning when it's unset.

  Env vars:
    EZTHROTTLE_MEMORY_LIMIT_MB      - reject new jobs once BEAM's total
                                       memory exceeds this many MB
                                       (default: disabled)
    EZTHROTTLE_MAX_BODY_BYTES       - reject oversized request bodies (413)
                                       (default: 1MB)
    EZTHROTTLE_DB_MAX_BYTES         - reject new jobs once the Mnesia
                                       directory exceeds this many bytes
                                       (default: 800MB)
    EZTHROTTLE_RETRY_AFTER_SECONDS  - base Retry-After on a 429 (default 5)

  Retry-After doubles on each consecutive rejection (capped at 60s),
  resetting the moment a request is allowed again — see retry_after_seconds/0.
  """

  use Agent
  require Logger

  @max_retry_after_seconds 60
  @default_max_body_bytes 1 * 1024 * 1024
  @default_db_max_bytes 800 * 1024 * 1024

  def start_link(_opts) do
    if env_int("EZTHROTTLE_MEMORY_LIMIT_MB", 0) == 0 do
      Logger.warning(
        "[Admission] EZTHROTTLE_MEMORY_LIMIT_MB is not set — BEAM memory is unbounded. " <>
          "Benchmarked safe at 400MB on a 512MB instance; set it to protect against OOM under burst load."
      )
    end

    Agent.start_link(fn -> %{reject_streak: 0} end, name: __MODULE__)
  end

  def memory_limit_mb, do: env_int("EZTHROTTLE_MEMORY_LIMIT_MB", 0)
  def max_body_bytes, do: env_int("EZTHROTTLE_MAX_BODY_BYTES", @default_max_body_bytes)
  def db_max_bytes, do: env_int("EZTHROTTLE_DB_MAX_BYTES", @default_db_max_bytes)
  def base_retry_after_seconds, do: env_int("EZTHROTTLE_RETRY_AFTER_SECONDS", 5)

  @doc "True if at least one limit is actually configured, not just whether this process is running."
  def any_limit_configured? do
    memory_limit_mb() > 0 or max_body_bytes() > 0 or db_max_bytes() > 0
  end

  @doc """
  Returns :ok if the request is admitted, or {:rejected, reason, limit, current}.
  reason is "memory" or "db_size", matching Aquifer's AdmissionDecision.
  """
  def check do
    cond do
      memory_limit_mb() > 0 and current_memory_mb() > memory_limit_mb() ->
        record_rejection()
        {:rejected, "memory", memory_limit_mb(), current_memory_mb()}

      db_max_bytes() > 0 and mnesia_dir_bytes() > db_max_bytes() ->
        record_rejection()
        {:rejected, "db_size", db_max_bytes(), mnesia_dir_bytes()}

      true ->
        record_allowed()
        :ok
    end
  end

  @doc """
  Base value on the first rejection, doubling per consecutive rejection
  (capped at #{@max_retry_after_seconds}s), reset to base the moment a
  request is allowed again.
  """
  def retry_after_seconds do
    base = base_retry_after_seconds()
    streak = Agent.get(__MODULE__, & &1.reject_streak)

    if streak <= 1 do
      base
    else
      backoff =
        Enum.reduce(2..streak//1, base, fn _, acc ->
          if acc < @max_retry_after_seconds, do: acc * 2, else: acc
        end)

      min(backoff, @max_retry_after_seconds)
    end
  end

  @doc "Snapshot for GET /health, independent of whether a request is currently being rejected."
  def snapshot do
    %{
      enabled: any_limit_configured?(),
      memory_mb: current_memory_mb(),
      memory_limit_mb: memory_limit_mb(),
      db_bytes: mnesia_dir_bytes(),
      db_max_bytes: db_max_bytes(),
      max_body_bytes: max_body_bytes(),
      retry_after_seconds: retry_after_seconds()
    }
  end

  # ---- Private ----

  defp record_rejection do
    Agent.update(__MODULE__, fn s -> %{s | reject_streak: s.reject_streak + 1} end)
  end

  defp record_allowed do
    Agent.update(__MODULE__, fn s -> %{s | reject_streak: 0} end)
  end

  defp current_memory_mb do
    div(:erlang.memory(:total), 1_048_576)
  end

  defp mnesia_dir_bytes do
    dir = :mnesia.system_info(:directory)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(fn f ->
          case File.stat(Path.join(dir, f)) do
            {:ok, %File.Stat{size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      _ ->
        0
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
