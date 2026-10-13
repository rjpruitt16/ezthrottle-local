# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.WebSocketBudget do
  @moduledoc """
  Bounds the space WebSocket transcripts use on this node, when they're kept
  in the local store (no SPILLWAY_VALKEY_URL).

  Transcripts used to live in Mnesia `disc_copies` tables, held in RAM; they
  are now in RocksDB (Spillway.WebSocketStore), but the budget still follows
  memory, so a node's transcripts stay a bounded share of it.
  Retention was only per session (`SPILLWAY_WS_STREAM_MAX_EVENTS`,
  default 10,000), so the total grew with the number of sessions: 500 busy
  sessions could hold 5M events, more than a 2 GB machine has. In the Fly
  lab that looked like a leak of about 4 MB/s (#24).

  The budget is `SPILLWAY_WS_TRANSCRIPT_MAX_MB` when set. Otherwise it
  is whatever room the rest of the node leaves under a memory target, and
  never more than a quarter of memory. The target is 90% of
  `SPILLWAY_MEMORY_LIMIT_MB` when set, otherwise 40% of the machine's
  (or container's) memory: the process's resident size runs about 1.4x
  what the VM reports, and a fixed quarter of a 2 GB machine (492 MB) got
  the node OOM-killed in the Fly lab once overload grew the rest of its
  memory to ~550 MB. While transcripts are over budget,
  every session is limited to an equal share of it, so the largest
  transcripts lose their oldest events first. A client whose cursor falls
  out of the retained range gets 409 on reconnect, as with any other
  retention limit. Under budget, only the per-session limit applies.
  """

  import Bitwise, only: [<<<: 2]

  @max_share_of_memory 0.25
  @target_share_of_memory 0.4
  @target_share_of_limit 0.9
  @min_budget_mb 16
  @fallback_budget_mb 128
  # Sessions keep at least this many events however many there are. With
  # enough sessions that floor alone exceeds the budget; refusing new
  # sessions at that point is SPILLWAY_MEMORY_LIMIT_MB admission's job.
  @min_events_per_session 10

  @doc "The current per-session event limit, or nil when transcripts are under budget."
  def session_limit do
    case :atomics.get(ref(), 1) do
      0 -> nil
      limit -> limit
    end
  end

  @doc """
  Measures transcript memory and sets the per-session limit. Returns the
  limit (nil when under budget).
  """
  def refresh(used_bytes, events, streams, budget_bytes \\ budget_bytes(nil)) do
    limit = limit_for(used_bytes, events, streams, budget_bytes)
    :atomics.put(ref(), 1, limit || 0)
    limit
  end

  @doc false
  def limit_for(used_bytes, _events, _streams, budget_bytes) when used_bytes <= budget_bytes,
    do: nil

  def limit_for(used_bytes, events, streams, budget_bytes) do
    bytes_per_event = used_bytes / max(events, 1)
    events_in_budget = budget_bytes / bytes_per_event
    max(trunc(events_in_budget / max(streams, 1)), @min_events_per_session)
  end

  @doc """
  The transcript budget in bytes. `transcript_bytes` is what transcripts
  use now (nil: count all VM memory as other use), so the rest of the
  node's memory can be measured.
  """
  def budget_bytes(transcript_bytes) do
    case env_int("SPILLWAY_WS_TRANSCRIPT_MAX_MB") do
      mb when is_integer(mb) and mb > 0 ->
        mb * 1_048_576

      _ ->
        other = :erlang.memory(:total) - (transcript_bytes || 0)

        derive_budget_bytes(
          system_memory_mb(),
          env_int("SPILLWAY_MEMORY_LIMIT_MB"),
          other
        )
    end
  end

  @doc false
  def derive_budget_bytes(nil, limit_mb, other) when not is_integer(limit_mb) or limit_mb <= 0,
    do: derive_budget_bytes(@fallback_budget_mb * 4, nil, other)

  def derive_budget_bytes(system_mb, limit_mb, other_bytes) do
    {memory_mb, target_mb} =
      if is_integer(limit_mb) and limit_mb > 0,
        do: {limit_mb, limit_mb * @target_share_of_limit},
        else: {system_mb, system_mb * @target_share_of_memory}

    headroom = trunc(target_mb * 1_048_576) - other_bytes
    ceiling = trunc(memory_mb * @max_share_of_memory * 1_048_576)
    headroom |> min(ceiling) |> max(@min_budget_mb * 1_048_576)
  end

  @doc """
  The memory available to this process in MB: the smaller of the cgroup
  limit (a container's or Fly machine's size) and physical memory. nil
  where neither can be read (e.g. macOS).
  """
  def system_memory_mb do
    [cgroup_limit_bytes(), meminfo_total_bytes()]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> div(Enum.min(values), 1_048_576)
    end
  end

  defp cgroup_limit_bytes do
    ["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"]
    |> Enum.find_value(fn path ->
      with {:ok, raw} <- File.read(path),
           {bytes, _} <- Integer.parse(String.trim(raw)),
           # cgroup v1 reports "no limit" as a number near 2^63.
           true <- bytes < 1 <<< 50 do
        bytes
      else
        _ -> nil
      end
    end)
  end

  defp meminfo_total_bytes do
    with {:ok, raw} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/MemTotal:\s+(\d+) kB/, raw) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  defp ref do
    case :persistent_term.get({__MODULE__, :ref}, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put({__MODULE__, :ref}, ref)
        ref

      ref ->
        ref
    end
  end

  defp env_int(name) do
    case Integer.parse(System.get_env(name, "")) do
      {value, ""} -> value
      _ -> nil
    end
  end
end
