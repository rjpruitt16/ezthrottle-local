defmodule EzthrottleLocal.WebSocketStore do
  @moduledoc false

  use GenServer

  require Logger

  alias EzthrottleLocal.WebSocketConfig

  @streams :websocket_streams
  @events :websocket_events
  @cleanup_interval_ms 60_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def ensure_tables! do
    nodes = [node()]

    ensure_table(
      @streams,
      [:session_hash, :epoch, :next_sequence, :oldest_sequence, :newest_sequence, :expires_at],
      :set,
      nodes
    )

    ensure_table(
      @events,
      [:key, :direction, :envelope, :recorded_at],
      :ordered_set,
      nodes
    )

    case :mnesia.wait_for_tables([@streams, @events], 30_000) do
      :ok -> :ok
      {:timeout, tables} -> raise "Mnesia WebSocket tables unavailable: #{inspect(tables)}"
      {:error, reason} -> raise "Mnesia WebSocket tables failed: #{inspect(reason)}"
    end
  end

  def append(session_id, direction, envelope) when direction in ["client", "backend"] do
    config = WebSocketConfig.load()
    session_hash = hash_session(session_id)
    now = System.system_time(:millisecond)

    case :mnesia.sync_transaction(fn ->
           stream = current_stream(session_hash, now)
           {epoch, next_sequence, oldest_sequence, _newest_sequence} = stream
           sequence = next_sequence + 1
           expires_at = now + config.stream_ttl_ms
           oldest = prune_for_limit(session_hash, epoch, oldest_sequence, sequence, config)
           key = {session_hash, epoch, sequence}

           :mnesia.write({@events, key, direction, envelope, now})

           :mnesia.write({@streams, session_hash, epoch, sequence, oldest, sequence, expires_at})

           %{
             stream_id: format_cursor(epoch, sequence),
             direction: direction,
             envelope: envelope,
             recorded_at: now
           }
         end) do
      {:atomic, event} -> {:ok, event}
      {:aborted, reason} -> {:error, reason}
    end
  end

  def check_cursor(session_id, cursor) do
    with {:ok, parsed} <- parse_cursor(cursor) do
      session_hash = hash_session(session_id)
      now = System.system_time(:millisecond)

      case :mnesia.transaction(fn -> validate_cursor(session_hash, parsed, now) end) do
        {:atomic, result} -> result
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  def read_after(session_id, cursor, limit) when is_integer(limit) and limit > 0 do
    with {:ok, parsed} <- parse_cursor(cursor) do
      session_hash = hash_session(session_id)
      now = System.system_time(:millisecond)

      case :mnesia.transaction(fn -> read_events(session_hash, parsed, limit, now) end) do
        {:atomic, result} -> result
        {:aborted, reason} -> {:error, reason}
      end
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
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, config}
  end

  @impl true
  def handle_info(:cleanup, config) do
    cleanup_expired()
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, config}
  end

  defp current_stream(session_hash, now) do
    case :mnesia.read(@streams, session_hash, :write) do
      [{@streams, ^session_hash, epoch, next_sequence, oldest, newest, expires_at}]
      when expires_at > now ->
        {epoch, next_sequence, oldest, newest}

      [{@streams, ^session_hash, epoch, _next_sequence, oldest, newest, _expires_at}] ->
        delete_event_range(session_hash, epoch, oldest, newest)
        {new_epoch(now, epoch), 0, 1, 0}

      [] ->
        {now, 0, 1, 0}
    end
  end

  defp prune_for_limit(session_hash, epoch, oldest, newest, config) do
    retained = newest - oldest + 1

    if retained <= config.stream_max_events do
      oldest
    else
      new_oldest = newest - config.stream_max_events + 1
      delete_event_range(session_hash, epoch, oldest, new_oldest - 1)
      new_oldest
    end
  end

  defp validate_cursor(_session_hash, {0, 0}, _now), do: :ok

  defp validate_cursor(session_hash, {cursor_epoch, cursor_sequence}, now) do
    case :mnesia.read(@streams, session_hash) do
      [{@streams, ^session_hash, epoch, _next, oldest, _newest, expires_at}]
      when expires_at > now and epoch == cursor_epoch and cursor_sequence >= oldest ->
        :ok

      _ ->
        {:error, :replay_gap}
    end
  end

  defp read_events(session_hash, {cursor_epoch, cursor_sequence}, limit, now) do
    case :mnesia.read(@streams, session_hash) do
      [] ->
        if {cursor_epoch, cursor_sequence} == {0, 0}, do: {:ok, []}, else: {:error, :replay_gap}

      [{@streams, ^session_hash, _epoch, _next, _oldest, _newest, expires_at}]
      when expires_at <= now ->
        if {cursor_epoch, cursor_sequence} == {0, 0}, do: {:ok, []}, else: {:error, :replay_gap}

      [{@streams, ^session_hash, epoch, _next, oldest, newest, _expires_at}] ->
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
    first..min(last, first + limit - 1)
    |> Enum.flat_map(fn sequence ->
      case :mnesia.read(@events, {session_hash, epoch, sequence}) do
        [{@events, _key, direction, envelope, recorded_at}] ->
          [
            %{
              stream_id: format_cursor(epoch, sequence),
              direction: direction,
              envelope: envelope,
              recorded_at: recorded_at
            }
          ]

        [] ->
          []
      end
    end)
  end

  defp cleanup_expired do
    now = System.system_time(:millisecond)

    case :mnesia.transaction(fn ->
           :mnesia.select(@streams, [
             {{@streams, :"$1", :"$2", :_, :"$3", :"$4", :"$5"}, [{:"=<", :"$5", now}],
              [{{:"$1", :"$2", :"$3", :"$4"}}]}
           ])
         end) do
      {:atomic, expired} ->
        Enum.each(expired, fn {session_hash, epoch, oldest, newest} ->
          :mnesia.transaction(fn ->
            delete_event_range(session_hash, epoch, oldest, newest)
            :mnesia.delete({@streams, session_hash})
          end)
        end)

      {:aborted, reason} ->
        Logger.warning("WebSocket stream cleanup failed: #{inspect(reason)}")
    end
  end

  defp delete_event_range(_session_hash, _epoch, first, last) when first > last, do: :ok

  defp delete_event_range(session_hash, epoch, first, last) do
    Enum.each(first..last, fn sequence ->
      :mnesia.delete({@events, {session_hash, epoch, sequence}})
    end)
  end

  defp ensure_table(name, attributes, type, nodes) do
    case :mnesia.create_table(name,
           attributes: attributes,
           disc_copies: nodes,
           type: type
         ) do
      {:atomic, :ok} -> Logger.info("[Mnesia] created table #{name}")
      {:aborted, {:already_exists, ^name}} -> :ok
      {:aborted, reason} -> raise "failed to create #{name}: #{inspect(reason)}"
    end
  end

  defp hash_session(session_id),
    do: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)

  defp format_cursor(epoch, sequence), do: "#{epoch}-#{sequence}"
  defp new_epoch(now, previous), do: max(now, previous + 1)

  defp compare(left, right) when left < right, do: :lt
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :eq
end
