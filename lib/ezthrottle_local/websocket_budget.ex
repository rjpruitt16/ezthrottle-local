defmodule EzthrottleLocal.WebSocketBudget do
  @moduledoc """
  Bounds the memory WebSocket transcripts use on this node.

  Transcripts live in Mnesia `disc_copies` tables, which are held in RAM.
  Retention was only per session (`EZTHROTTLE_WS_STREAM_MAX_EVENTS`,
  default 10,000), so the total grew with the number of sessions: 500 busy
  sessions could hold 5M events, more than a 2 GB machine has. In the Fly
  lab that looked like a leak of about 4 MB/s (#24).

  The budget is `EZTHROTTLE_WS_TRANSCRIPT_MAX_MB` when set, otherwise a
  quarter of `EZTHROTTLE_MEMORY_LIMIT_MB`, otherwise a quarter of the
  machine's (or container's) memory. While transcripts are over budget,
  every session is limited to an equal share of it, so the largest
  transcripts lose their oldest events first. A client whose cursor falls
  out of the retained range gets 409 on reconnect, as with any other
  retention limit. Under budget, only the per-session limit applies.
  """

  import Bitwise, only: [<<<: 2]

  @share_of_memory 0.25
  @fallback_budget_mb 256
  # Sessions keep at least this many events however many there are. With
  # enough sessions that floor alone exceeds the budget; refusing new
  # sessions at that point is EZTHROTTLE_MEMORY_LIMIT_MB admission's job.
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
  def refresh(used_bytes, events, streams, budget_bytes \\ budget_bytes()) do
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

  def budget_bytes do
    mb =
      case env_int("EZTHROTTLE_WS_TRANSCRIPT_MAX_MB") do
        mb when is_integer(mb) and mb > 0 -> mb
        _ -> derived_budget_mb()
      end

    mb * 1_048_576
  end

  defp derived_budget_mb do
    memory_mb =
      case env_int("EZTHROTTLE_MEMORY_LIMIT_MB") do
        mb when is_integer(mb) and mb > 0 -> mb
        _ -> system_memory_mb()
      end

    case memory_mb do
      nil -> @fallback_budget_mb
      mb -> max(trunc(mb * @share_of_memory), 1)
    end
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
