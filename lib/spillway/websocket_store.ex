# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.WebSocketStore do
  @moduledoc false

  use GenServer

  require Logger

  alias Spillway.{Store, WebSocketBudget, WebSocketConfig}
  alias Spillway.WebSocketStore.Valkey

  @owners Spillway.WebSocketStreamOwners
  @cleanup_interval_ms 60_000
  # The budget pass trims only streams idle this long: an active stream is
  # trimmed on its own appends, and trimming it here as well contends with
  # them for the stream's lock, which under load delayed the pass by minutes.
  @idle_before_trim_ms 5_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Loads the transcript counts. Called once at boot, after Spillway.Store
  is open.
  """
  def ensure_tables! do
    {events, bytes} =
      Store.fold(:ws_events, {0, 0}, fn {_key, value}, {n, b} ->
        {n + 1, b + :erlang.external_size(value)}
      end)

    streams = Store.fold(:ws_streams, 0, fn _, n -> n + 1 end)
    ref = usage_counters()
    :atomics.put(ref, 1, events)
    :atomics.put(ref, 2, streams)
    :atomics.put(ref, 3, bytes)
    :atomics.put(ref, 4, events)
    :ok
  end

  # Every stream has one writer: the session process that claimed it (see
  # claim_stream/1), or this GenServer while it holds the claim for cleanup
  # or a budget trim. So appends and replay reads need no transaction: a
  # stream's event and its new head are written as one atomic batch.

  @doc """
  Makes the calling process the only writer of the session's stream. Called
  by the session process; the claim ends when it exits. Waits while a
  cleanup or trim pass holds the stream.
  """
  def claim_stream(session_id, attempts \\ 200) do
    case Registry.register(@owners, hash_session(session_id), :session) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _pid}} when attempts > 0 ->
        Process.sleep(5)
        claim_stream(session_id, attempts - 1)

      {:error, {:already_registered, pid}} ->
        {:error, {:stream_owned_by, pid}}
    end
  end

  # For this GenServer's passes: claims a stream nobody owns, runs fun and
  # releases it. A live session's stream is left to the session.
  defp with_unowned_stream(session_hash, fun) do
    case Registry.register(@owners, session_hash, :maintenance) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(@owners, session_hash)
        end

      {:error, {:already_registered, pid}} ->
        {:owned, pid}
    end
  end

  # With SPILLWAY_VALKEY_URL set, transcripts live in Valkey streams
  # (Spillway.WebSocketStore.Valkey) and the RocksDB code below is unused.

  def append(session_id, direction, envelope) when direction in ["client", "backend"] do
    if Valkey.enabled?(),
      do: Valkey.append(hash_session(session_id), direction, envelope, WebSocketConfig.load()),
      else: append_local(session_id, direction, envelope)
  end

  defp append_local(session_id, direction, envelope) do
    config = WebSocketConfig.load()
    session_hash = hash_session(session_id)
    now = System.system_time(:millisecond)

    {epoch, next_sequence, oldest_sequence, _newest_sequence} = current_stream(session_hash, now)
    sequence = next_sequence + 1
    expires_at = now + config.stream_ttl_ms
    oldest = prune_for_limit(session_hash, epoch, oldest_sequence, sequence, config)
    value = {direction, envelope, now}

    Store.write([
      {:put, :ws_events, event_key(session_hash, epoch, sequence), value},
      {:put, :ws_streams, session_hash, {epoch, sequence, oldest, sequence, expires_at}}
    ])

    count_appended(:erlang.external_size(value))

    {:ok,
     %{
       stream_id: format_cursor(epoch, sequence),
       direction: direction,
       envelope: envelope,
       recorded_at: now
     }}
  end

  @doc """
  Trims the caller's own stream to limit events. The budget pass sends a
  live session {:trim_transcript, limit}, and the session calls this.
  """
  def trim_owned(session_id, limit) do
    unless Valkey.enabled?() do
      trim_stream(hash_session(session_id), limit)
    end

    :ok
  end

  defp trim_stream(session_hash, limit) do
    case Store.get(:ws_streams, session_hash) do
      {:ok, {epoch, next, oldest, newest, expires_at}} ->
        new_oldest = trim_to(session_hash, epoch, oldest, newest, limit)
        Store.put(:ws_streams, session_hash, {epoch, next, new_oldest, newest, expires_at})

      :not_found ->
        :ok
    end
  end

  def check_cursor(session_id, cursor) do
    with {:ok, parsed} <- parse_cursor(cursor) do
      if Valkey.enabled?(),
        do: Valkey.check_cursor(hash_session(session_id), parsed),
        else: validate_cursor(hash_session(session_id), parsed, System.system_time(:millisecond))
    end
  end

  def read_after(session_id, cursor, limit) when is_integer(limit) and limit > 0 do
    with {:ok, parsed} <- parse_cursor(cursor) do
      if Valkey.enabled?(),
        do: Valkey.read_after(hash_session(session_id), parsed, limit),
        else:
          read_events(hash_session(session_id), parsed, limit, System.system_time(:millisecond))
    end
  end

  def parse_cursor(nil), do: {:ok, {0, 0}}
  def parse_cursor(""), do: {:ok, {0, 0}}
  def parse_cursor("0-0"), do: {:ok, {0, 0}}

  def parse_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, "-", parts: 2) do
      [epoch, sequence] ->
        with {parsed_epoch, ""} when parsed_epoch >= 0 <- Integer.parse(epoch),
             {parsed_sequence, ""} when parsed_sequence >= 0 <- Integer.parse(sequence) do
          {:ok, {parsed_epoch, parsed_sequence}}
        else
          _ -> {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  def compare_cursors(left, right) do
    with {:ok, parsed_left} <- parse_cursor(left),
         {:ok, parsed_right} <- parse_cursor(right) do
      {:ok, compare(parsed_left, parsed_right)}
    end
  end

  @impl true
  def init(config) do
    # Valkey expires and caps streams itself.
    unless Valkey.enabled?() do
      Process.send_after(self(), :cleanup, @cleanup_interval_ms)
      schedule_budget()
    end

    {:ok, config}
  end

  @impl true
  def handle_info(:cleanup, config) do
    cleanup_expired()
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, config}
  end

  def handle_info(:budget, config) do
    enforce_budget()
    schedule_budget()
    {:noreply, config}
  end

  # 0 turns the periodic check off (tests call enforce_budget/1 directly).
  defp schedule_budget do
    case Application.get_env(:spillway, :websocket_budget_interval_ms, 2_000) do
      0 -> :ok
      interval -> Process.send_after(self(), :budget, interval)
    end
  end

  @doc """
  Measures transcript memory against WebSocketBudget and, when over, trims
  every stream to the per-session limit. Active streams are also trimmed on
  each append; this pass catches idle ones.
  """
  def enforce_budget(budget_bytes \\ nil, idle_ms \\ @idle_before_trim_ms)

  def enforce_budget(budget_bytes, idle_ms) do
    if Valkey.enabled?(), do: :ok, else: enforce_budget_local(budget_bytes, idle_ms)
  end

  defp enforce_budget_local(budget_bytes, idle_ms) do
    {used, events, streams} = usage()
    budget_bytes = budget_bytes || WebSocketBudget.budget_bytes(used)

    case WebSocketBudget.refresh(used, events, streams, budget_bytes) do
      nil -> :ok
      limit -> trim_streams_over(limit, idle_ms)
    end
  end

  @doc "Transcript memory for GET /health."
  def budget_snapshot do
    if Valkey.enabled?(),
      do: %{transcript_store: "valkey"},
      else: budget_snapshot_local()
  end

  defp budget_snapshot_local do
    {used, events, streams} = usage()

    %{
      transcript_mb: div(used, 1_048_576),
      transcript_budget_mb: div(WebSocketBudget.budget_bytes(used), 1_048_576),
      transcript_events: events,
      transcript_sessions: streams,
      session_event_limit: WebSocketBudget.session_limit()
    }
  end

  # Transcript size, from running counts: events and streams held, and the
  # bytes and count of every event appended, for an average event size.
  # Slots: 1 events, 2 streams, 3 bytes appended, 4 events appended.
  defp usage do
    ref = usage_counters()
    events = max(:atomics.get(ref, 1), 0)
    per_event = :atomics.get(ref, 3) / max(:atomics.get(ref, 4), 1)
    {trunc(events * per_event), events, max(:atomics.get(ref, 2), 0)}
  end

  defp usage_counters do
    case :persistent_term.get({__MODULE__, :usage}, nil) do
      nil ->
        ref = :atomics.new(4, signed: true)
        :persistent_term.put({__MODULE__, :usage}, ref)
        ref

      ref ->
        ref
    end
  end

  defp count_appended(bytes) do
    ref = usage_counters()
    :atomics.add(ref, 1, 1)
    :atomics.add(ref, 3, bytes)
    :atomics.add(ref, 4, 1)
  end

  defp trim_streams_over(limit, idle_ms) do
    # expires_at is the last append plus the TTL.
    ttl_ms = WebSocketConfig.load().stream_ttl_ms
    idle_expiry = System.system_time(:millisecond) + ttl_ms - idle_ms

    over =
      Store.fold(:ws_streams, [], fn {session_hash, {_epoch, _next, oldest, newest, expires_at}},
                                     acc ->
        if newest - oldest > limit - 1 and expires_at <= idle_expiry,
          do: [session_hash | acc],
          else: acc
      end)

    Enum.each(over, fn session_hash ->
      case with_unowned_stream(session_hash, fn -> trim_stream(session_hash, limit) end) do
        {:owned, pid} -> send(pid, {:trim_transcript, limit})
        _ -> :ok
      end
    end)
  end

  defp current_stream(session_hash, now) do
    case Store.get(:ws_streams, session_hash) do
      {:ok, {epoch, next_sequence, oldest, newest, expires_at}} when expires_at > now ->
        {epoch, next_sequence, oldest, newest}

      {:ok, {epoch, _next_sequence, oldest, newest, _expires_at}} ->
        delete_event_range(session_hash, epoch, oldest, newest)
        {new_epoch(now, epoch), 0, 1, 0}

      :not_found ->
        :atomics.add(usage_counters(), 2, 1)
        {now, 0, 1, 0}
    end
  end

  defp prune_for_limit(session_hash, epoch, oldest, newest, config) do
    limit =
      case WebSocketBudget.session_limit() do
        nil -> config.stream_max_events
        budget_limit -> min(config.stream_max_events, budget_limit)
      end

    trim_to(session_hash, epoch, oldest, newest, limit)
  end

  defp trim_to(session_hash, epoch, oldest, newest, limit) do
    if newest - oldest + 1 <= limit do
      oldest
    else
      new_oldest = newest - limit + 1
      delete_event_range(session_hash, epoch, oldest, new_oldest - 1)
      new_oldest
    end
  end

  defp validate_cursor(_session_hash, {0, 0}, _now), do: :ok

  defp validate_cursor(session_hash, {cursor_epoch, cursor_sequence}, now) do
    case Store.get(:ws_streams, session_hash) do
      {:ok, {epoch, _next, oldest, _newest, expires_at}}
      when expires_at > now and epoch == cursor_epoch and cursor_sequence >= oldest ->
        :ok

      _ ->
        {:error, :replay_gap}
    end
  end

  defp read_events(session_hash, {cursor_epoch, cursor_sequence}, limit, now) do
    case Store.get(:ws_streams, session_hash) do
      :not_found ->
        if {cursor_epoch, cursor_sequence} == {0, 0}, do: {:ok, []}, else: {:error, :replay_gap}

      {:ok, {_epoch, _next, _oldest, _newest, expires_at}} when expires_at <= now ->
        if {cursor_epoch, cursor_sequence} == {0, 0}, do: {:ok, []}, else: {:error, :replay_gap}

      {:ok, {epoch, _next, oldest, newest, _expires_at}} ->
        cond do
          {cursor_epoch, cursor_sequence} == {0, 0} ->
            {:ok, load_event_range(session_hash, epoch, oldest, newest, limit)}

          cursor_epoch != epoch or cursor_sequence < oldest ->
            {:error, :replay_gap}

          true ->
            {:ok, load_event_range(session_hash, epoch, cursor_sequence + 1, newest, limit)}
        end
    end
  end

  defp load_event_range(_session_hash, _epoch, first, last, _limit) when first > last, do: []

  defp load_event_range(session_hash, epoch, first, last, limit) do
    last = min(last, first + limit - 1)

    :ws_events
    |> Store.take_from(event_key(session_hash, epoch, first), last - first + 1, fn
      <<^session_hash::binary-size(byte_size(session_hash)), ^epoch::unsigned-64,
        seq::unsigned-64>> ->
        seq <= last

      _ ->
        false
    end)
    |> Enum.map(fn {<<_::binary-size(byte_size(session_hash)), _::unsigned-64,
                      sequence::unsigned-64>>, {direction, envelope, recorded_at}} ->
      %{
        stream_id: format_cursor(epoch, sequence),
        direction: direction,
        envelope: envelope,
        recorded_at: recorded_at
      }
    end)
  end

  defp cleanup_expired do
    now = System.system_time(:millisecond)

    expired =
      Store.fold(:ws_streams, [], fn {session_hash, {_, _, _, _, expires_at}}, acc ->
        if expires_at <= now, do: [session_hash | acc], else: acc
      end)

    # A live session's expired stream is left to it: its next append starts
    # a new epoch and deletes the old events itself.
    Enum.each(expired, fn session_hash ->
      with_unowned_stream(session_hash, fn ->
        case Store.get(:ws_streams, session_hash) do
          {:ok, {epoch, _next, oldest, newest, expires_at}} when expires_at <= now ->
            delete_event_range(session_hash, epoch, oldest, newest)
            Store.delete(:ws_streams, session_hash)
            :atomics.sub(usage_counters(), 2, 1)

          _ ->
            :ok
        end
      end)
    end)
  end

  defp delete_event_range(_session_hash, _epoch, first, last) when first > last, do: :ok

  defp delete_event_range(session_hash, epoch, first, last) do
    Store.delete_range(
      :ws_events,
      event_key(session_hash, epoch, first),
      event_key(session_hash, epoch, last + 1)
    )

    :atomics.sub(usage_counters(), 1, last - first + 1)
  end

  # Ordered by session, then epoch, then sequence, so a stream's events are
  # one contiguous key range.
  defp event_key(session_hash, epoch, sequence),
    do: <<session_hash::binary, epoch::unsigned-64, sequence::unsigned-64>>

  defp hash_session(session_id),
    do: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)

  defp format_cursor(epoch, sequence), do: "#{epoch}-#{sequence}"
  defp new_epoch(now, previous), do: max(now, previous + 1)

  defp compare(left, right) when left < right, do: :lt
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :eq
end
