# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.Admission do
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
    SPILLWAY_MEMORY_LIMIT_MB      - reject new jobs once the process's
                                       resident memory exceeds this many
                                       MB (default: disabled). Finished
                                       jobs are evicted before that point,
                                       see IdempotentStore.
    SPILLWAY_MAX_BODY_BYTES       - reject oversized request bodies (413)
                                       (default: 1MB)
    SPILLWAY_DB_MAX_BYTES         - reject new jobs once the Mnesia
                                       directory exceeds this many bytes
                                       (default: 800MB)
    SPILLWAY_STORE_MAX_BACKLOG    - reject new jobs once this many store
                                       writes are queued, see
                                       Spillway.StorePressure (default:
                                       5000; 0 disables)
    SPILLWAY_RETRY_AFTER_SECONDS  - base Retry-After on a 429 (default 5)

  Retry-After doubles on each consecutive rejection (capped at 60s),
  resetting the moment a request is allowed again — see retry_after_seconds/0.
  """

  use Agent
  require Logger

  @max_retry_after_seconds 60
  @default_max_body_bytes 1 * 1024 * 1024
  @default_db_max_bytes 800 * 1024 * 1024

  def start_link(_opts) do
    if env_int("SPILLWAY_MEMORY_LIMIT_MB", 0) == 0 do
      Logger.warning(
        "[Admission] SPILLWAY_MEMORY_LIMIT_MB is not set — BEAM memory is unbounded. " <>
          "Benchmarked safe at 400MB on a 512MB instance; set it to protect against OOM under burst load."
      )
    end

    counters()
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  # check/0 runs on every submission. Its state lives in :atomics (no
  # process), not the Agent: an Agent.update per request made every
  # submission take turns through one process. Slots: 1 reject streak,
  # 2 cached Mnesia dir bytes, 3 when they were read (ms), 4 cached memory
  # MB, 5 when it was read, 6 cached store backlog, 7 when it was read,
  # 8 cached fullness, 9 when it was read.
  @sample_ttl_ms 250

  defp counters do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil ->
        ref = :atomics.new(9, signed: true)
        :persistent_term.put({__MODULE__, :counters}, ref)
        ref

      ref ->
        ref
    end
  end

  # Both readings are expensive per request (stat-ing every Mnesia file;
  # summing BEAM memory) and barely move in a few hundred milliseconds.
  # Exactly one caller refreshes an expired reading; the rest keep using the
  # cached value. Without that, every request in flight when the reading
  # expired listed and stat-ed the Mnesia directory at once, and those
  # calls all queue on OTP's single :file_server process.
  defp sampled(value_slot, at_slot, read) do
    ref = counters()
    now = System.monotonic_time(:millisecond)
    at = :atomics.get(ref, at_slot)

    cond do
      at != 0 and now - at < @sample_ttl_ms ->
        :atomics.get(ref, value_slot)

      :atomics.compare_exchange(ref, at_slot, at, now) == :ok ->
        value = read.()
        :atomics.put(ref, value_slot, value)
        value

      # Another caller is refreshing. Before the very first reading there's
      # no cached value to fall back on.
      at == 0 ->
        read.()

      true ->
        :atomics.get(ref, value_slot)
    end
  end

  def memory_limit_mb, do: env_int("SPILLWAY_MEMORY_LIMIT_MB", 0)
  def max_body_bytes, do: env_int("SPILLWAY_MAX_BODY_BYTES", @default_max_body_bytes)
  def db_max_bytes, do: env_int("SPILLWAY_DB_MAX_BYTES", @default_db_max_bytes)
  def base_retry_after_seconds, do: env_int("SPILLWAY_RETRY_AFTER_SECONDS", 5)
  def store_max_backlog, do: env_int("SPILLWAY_STORE_MAX_BACKLOG", 5_000)

  @doc "True if at least one limit is actually configured, not just whether this process is running."
  def any_limit_configured? do
    memory_limit_mb() > 0 or max_body_bytes() > 0 or db_max_bytes() > 0 or
      store_max_backlog() > 0
  end

  @doc """
  Returns :ok if the request is admitted, or {:rejected, reason, limit, current}.
  reason is "memory" or "db_size", matching Aquifer's AdmissionDecision.
  """
  def check do
    cond do
      memory_limit_mb() > 0 and sampled_memory_mb() > memory_limit_mb() ->
        record_rejection()
        {:rejected, "memory", memory_limit_mb(), sampled_memory_mb()}

      db_max_bytes() > 0 and sampled_db_bytes() > db_max_bytes() ->
        record_rejection()
        {:rejected, "db_size", db_max_bytes(), sampled_db_bytes()}

      store_max_backlog() > 0 and sampled_store_backlog() > store_max_backlog() ->
        record_rejection()
        {:rejected, "store_backlog", store_max_backlog(), sampled_store_backlog()}

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
    streak = :atomics.get(counters(), 1)

    # Doubling a positive base passes the cap within a few steps, so cap the
    # exponent instead of looping once per rejection. The loop this replaces
    # ran over the whole streak on every 429: under sustained overload in
    # soak run 3d (over a million rejections) it took about 70% of the CPU.
    cond do
      streak <= 1 or base <= 0 -> base
      true -> min(base * Integer.pow(2, min(streak - 1, 16)), @max_retry_after_seconds)
    end
  end

  @doc """
  How full this node is, 0-100, for the `x-aqueduct-fullness` response
  header (SpillwayWeb.Plugs.Fullness) and the registration ping. It's the
  most-constrained of the limits this node already enforces -- memory,
  the Mnesia directory, the store write backlog, and the fullest
  upstream's backlog against its budget (Spillway.Intake) -- because that's
  the one that will start turning work away first. Limits that are
  switched off don't count. Same contract as Aquifer's X-Aqueduct-Fullness:
  unlike admission pressure, which stays at 0 until fair admission's 70%
  starting point, it rises from the first queued job, so whatever is in
  front of this node (Canalis, or a client) sees it filling up before it
  pushes back. Sampled at most every #{@sample_ttl_ms}ms, like the readings
  behind it.
  """
  def fullness, do: sampled(8, 9, &compute_fullness/0)

  @doc false
  def compute_fullness do
    [
      memory_limit_mb() > 0 and sampled_memory_mb() / memory_limit_mb(),
      db_max_bytes() > 0 and sampled_db_bytes() / db_max_bytes(),
      store_max_backlog() > 0 and sampled_store_backlog() / store_max_backlog(),
      Spillway.Intake.backlog_fullness_ratio()
    ]
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> 0.0 end)
    |> min(1.0)
    |> max(0.0)
    |> Kernel.*(100)
    |> round()
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
      store_backlog: Spillway.StorePressure.backlog(),
      store_max_backlog: store_max_backlog(),
      store_queues: Spillway.StorePressure.detail(),
      processes: :erlang.system_info(:process_count),
      vm_memory_mb: Spillway.MemoryUsage.vm_mb(),
      storage: Spillway.IdempotentStore.storage(),
      retry_after_seconds: retry_after_seconds()
    }
  end

  # ---- Private ----

  defp record_rejection, do: :atomics.add(counters(), 1, 1)

  defp record_allowed do
    ref = counters()
    if :atomics.get(ref, 1) != 0, do: :atomics.put(ref, 1, 0)
    :ok
  end

  defp sampled_memory_mb, do: sampled(4, 5, &current_memory_mb/0)
  defp sampled_db_bytes, do: sampled(2, 3, &mnesia_dir_bytes/0)
  defp sampled_store_backlog, do: sampled(6, 7, &Spillway.StorePressure.backlog/0)

  defp current_memory_mb, do: Spillway.MemoryUsage.mb()

  # Everything under the Mnesia directory. RocksDB tables
  # (SPILLWAY_STORAGE=rocksdb) keep their files in subdirectories, which a
  # flat listing counted as a few KB each, so the limit never fired.
  defp mnesia_dir_bytes, do: dir_bytes(:mnesia.system_info(:directory))

  defp dir_bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> entries |> Enum.map(&dir_bytes(Path.join(path, &1))) |> Enum.sum()
          _ -> 0
        end

      {:ok, %File.Stat{size: size}} ->
        size

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
