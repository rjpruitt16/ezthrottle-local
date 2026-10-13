# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.Store do
  @moduledoc """
  The node's one RocksDB database: jobs, idempotency keys, results and the
  WebSocket transcript fallback, each in its own column family.

  This replaced Mnesia. Spillway's tables were always local to the node
  (cluster routing goes through syn, not Mnesia replication), and in soak
  run 3e the cost sat in the layers between Spillway and the disk: the
  mnesia_rocksdb adapter, whose defaults held about 700MB of write buffers
  outside the BEAM, and Mnesia's transaction and log processes. Callers now
  read and write RocksDB directly from their own processes; the handles live
  in :persistent_term and RocksDB is safe to call concurrently.

  Keys are binaries. Values are Erlang terms stored with term_to_binary.

  Durability: every write goes to RocksDB's write-ahead log before it
  returns, so a killed process loses nothing. `SPILLWAY_STORE_SYNC_INTERVAL_MS`
  bounds what a machine crash can lose by syncing the log to disk on a timer
  (default 100ms); 0 syncs on every write instead.

  The data lives under `SPILLWAY_STORE_DIR` (default `/data/spillway`,
  `priv/store` in development).
  """

  use GenServer

  require Logger

  @column_families ~w(jobs keys results delivery drain_events meta expiry ws_streams ws_events)a
  @default_sync_interval_ms 100

  # Small write buffers: with RocksDB's 64MB default, nine column families
  # could hold over a gigabyte of memtables outside the BEAM, where
  # admission's memory limit can't see it coming (soak run 3e).
  @cf_options [write_buffer_size: 8 * 1024 * 1024, max_write_buffer_number: 2]

  @db_options [
    create_if_missing: true,
    create_missing_column_families: true,
    # RocksDB keeps up to 1,000 old info logs by default.
    keep_log_file_num: 5,
    max_total_wal_size: 64 * 1024 * 1024
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Where the database lives."
  def dir, do: Application.get_env(:spillway, :store_dir, "priv/store")

  @doc """
  Opens the database. Called once at boot, before anything reads or writes;
  the GenServer started later only syncs the log and closes the database.
  """
  def open! do
    case :persistent_term.get({__MODULE__, :db}, nil) do
      nil ->
        path = dir()
        File.mkdir_p!(path)

        descriptors = [
          {~c"default", @cf_options} | Enum.map(@column_families, &{~c"#{&1}", @cf_options})
        ]

        {:ok, db, [_default | handles]} =
          :rocksdb.open(to_charlist(path), @db_options, descriptors)

        :persistent_term.put({__MODULE__, :db}, db)
        :persistent_term.put({__MODULE__, :cfs}, Map.new(Enum.zip(@column_families, handles)))
        Logger.info("[Store] opened #{path}")
        :ok

      _db ->
        :ok
    end
  end

  @doc "Reads a value: `{:ok, term}` or `:not_found`."
  def get(cf, key) do
    case :rocksdb.get(db(), cf(cf), key, []) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      :not_found -> :not_found
    end
  end

  def put(cf, key, value), do: write([{:put, cf, key, value}])
  def delete(cf, key), do: write([{:delete, cf, key}])

  @doc """
  Applies `{:put, cf, key, value}` and `{:delete, cf, key}` operations as one
  atomic batch: after a crash either all of them are there or none is.
  """
  def write([]), do: :ok

  def write(ops) do
    actions =
      Enum.map(ops, fn
        {:put, cf, key, value} -> {:put, cf(cf), key, :erlang.term_to_binary(value)}
        {:delete, cf, key} -> {:delete, cf(cf), key}
      end)

    :ok = :rocksdb.write(db(), actions, write_options())
  end

  @doc "Deletes every key in [first, last) from a column family."
  def delete_range(cf, first, last) do
    :ok = :rocksdb.delete_range(db(), cf(cf), first, last, write_options())
  end

  @doc "Folds over every `{key, value}` in a column family, in key order."
  def fold(cf, acc, fun) do
    :rocksdb.fold(
      db(),
      cf(cf),
      fn {k, v}, a -> fun.({k, :erlang.binary_to_term(v)}, a) end,
      acc,
      []
    )
  end

  @doc """
  Up to `limit` `{key, value}` pairs from `from` onwards, in key order, while
  `keep?.(key)` is true.
  """
  def take_from(cf, from, limit, keep?) do
    {:ok, it} = :rocksdb.iterator(db(), cf(cf), [])

    try do
      take(it, :rocksdb.iterator_move(it, {:seek, from}), limit, keep?, [])
    after
      :rocksdb.iterator_close(it)
    end
  end

  defp take(_it, _moved, 0, _keep?, acc), do: Enum.reverse(acc)

  defp take(it, {:ok, key, value}, limit, keep?, acc) do
    if keep?.(key),
      do:
        take(it, :rocksdb.iterator_move(it, :next), limit - 1, keep?, [
          {key, :erlang.binary_to_term(value)} | acc
        ]),
      else: Enum.reverse(acc)
  end

  defp take(_it, _end, _limit, _keep?, acc), do: Enum.reverse(acc)

  @doc "Deletes every key in every column family."
  def clear(cfs \\ @column_families) do
    Enum.each(cfs, fn cf ->
      keys = fold(cf, [], fn {k, _v}, acc -> [k | acc] end)

      keys
      |> Enum.chunk_every(1_000)
      |> Enum.each(&write(Enum.map(&1, fn k -> {:delete, cf, k} end)))
    end)
  end

  @doc "A RocksDB property for one column family, e.g. \"rocksdb.estimate-num-keys\"."
  def property(cf, name) do
    case :rocksdb.get_property(db(), cf(cf), name) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp db, do: :persistent_term.get({__MODULE__, :db})
  defp cf(name), do: Map.fetch!(:persistent_term.get({__MODULE__, :cfs}), name)

  defp write_options, do: if(sync_interval_ms() == 0, do: [sync: true], else: [])

  defp sync_interval_ms do
    case Integer.parse(System.get_env("SPILLWAY_STORE_SYNC_INTERVAL_MS", "")) do
      {n, ""} when n >= 0 -> n
      _ -> @default_sync_interval_ms
    end
  end

  # ---- GenServer: periodic log sync, close on shutdown ----

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Spillway.IdempotentStore.create_key_gate()
    schedule_sync()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sync, state) do
    :rocksdb.sync_wal(db())
    schedule_sync()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :rocksdb.sync_wal(db())
  end

  defp schedule_sync do
    case sync_interval_ms() do
      0 -> :ok
      interval -> Process.send_after(self(), :sync, interval)
    end
  end
end
