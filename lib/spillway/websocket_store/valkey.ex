# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.WebSocketStore.Valkey do
  @moduledoc """
  WebSocket transcripts in Valkey (or Redis) streams, the way Aquifer keeps
  them: one stream per session, appended with XADD and capped with MAXLEN,
  expiring SPILLWAY_WS_STREAM_TTL_SECONDS after its last append. Used when
  SPILLWAY_VALKEY_URL is set.

  A transcript is an append-only, capped, expiring log, which is what
  streams are for. Kept in Mnesia it cost a write per message through
  Mnesia's lock manager and log, and in soak run 3 competed with job writes
  for one CPU. Stream IDs (`<ms>-<seq>`) have the same form as the local
  store's cursors (Spillway.WebSocketStore), so clients see no difference.
  """

  @connections 4
  @prefix "spillway:ws:"

  @doc "The Valkey URL, or nil when transcripts stay in the local store."
  def url do
    case System.get_env("SPILLWAY_VALKEY_URL") do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  def enabled?, do: url() != nil

  @doc "The Redix connections, one supervisor child each."
  def child_specs do
    case url() do
      nil ->
        []

      url ->
        for i <- 0..(@connections - 1) do
          Supervisor.child_spec({Redix, {url, [name: conn_name(i)]}}, id: {__MODULE__, i})
        end
    end
  end

  defp conn_name(i), do: :"spillway_ws_valkey_#{i}"

  # A session always uses the same connection, so its appends stay in order.
  defp conn(session_hash), do: conn_name(:erlang.phash2(session_hash, @connections))

  defp key(session_hash), do: @prefix <> session_hash

  def append(session_hash, direction, envelope, config) do
    now = System.system_time(:millisecond)
    key = key(session_hash)

    commands = [
      [
        "XADD",
        key,
        "MAXLEN",
        "~",
        Integer.to_string(config.stream_max_events),
        "*",
        "direction",
        direction,
        "envelope",
        Jason.encode!(envelope),
        "recorded_at",
        Integer.to_string(now)
      ],
      ["PEXPIRE", key, Integer.to_string(config.stream_ttl_ms)]
    ]

    case Redix.pipeline(conn(session_hash), commands) do
      {:ok, [id, _]} when is_binary(id) ->
        {:ok, %{stream_id: id, direction: direction, envelope: envelope, recorded_at: now}}

      {:ok, [error | _]} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def check_cursor(_session_hash, {0, 0}), do: :ok

  def check_cursor(session_hash, cursor) do
    case oldest(session_hash) do
      {:ok, nil} -> {:error, :replay_gap}
      {:ok, oldest} -> if cursor < oldest, do: {:error, :replay_gap}, else: :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def read_after(session_hash, {0, 0}, limit) do
    range(session_hash, "-", limit)
  end

  # Events after the cursor, or a gap if the transcript no longer reaches
  # back to it (trimmed by MAXLEN, or expired).
  def read_after(session_hash, cursor, limit) do
    with :ok <- check_cursor(session_hash, cursor) do
      range(session_hash, "(" <> format(cursor), limit)
    end
  end

  defp oldest(session_hash) do
    case Redix.command(conn(session_hash), ["XRANGE", key(session_hash), "-", "+", "COUNT", "1"]) do
      {:ok, [[id | _] | _]} -> {:ok, parse_id(id)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp range(session_hash, start, limit) do
    command = ["XRANGE", key(session_hash), start, "+", "COUNT", Integer.to_string(limit)]

    case Redix.command(conn(session_hash), command) do
      {:ok, entries} -> {:ok, Enum.map(entries, &decode/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode([id, fields]) do
    fields = fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)

    %{
      stream_id: id,
      direction: fields["direction"],
      envelope: Jason.decode!(fields["envelope"]),
      recorded_at: String.to_integer(fields["recorded_at"])
    }
  end

  defp parse_id(id) do
    [ms, seq] = String.split(id, "-", parts: 2)
    {String.to_integer(ms), String.to_integer(seq)}
  end

  defp format({ms, seq}), do: "#{ms}-#{seq}"
end
