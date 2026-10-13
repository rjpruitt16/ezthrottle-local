# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.StorePressure do
  @moduledoc """
  How far the job store is behind: messages queued at the IdempotentStore
  GenServer, which serves store calls routed from other nodes and the
  expiry pass. Most writes go straight to RocksDB from the caller's process
  (Spillway.Store) and queue nowhere. In soak run 3c, when every write
  passed through Mnesia's processes, those queues reached 10,000 while new
  jobs kept being admitted, and the callers waiting on them used enough
  memory to get the node killed. Admission refuses new jobs past
  SPILLWAY_STORE_MAX_BACKLOG instead.
  """

  @named [Spillway.IdempotentStore]

  @doc "Messages queued across the store's processes."
  def backlog do
    Enum.reduce(store_processes(), 0, fn name, total ->
      case Process.whereis(name) do
        nil ->
          total

        pid ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, n} -> total + n
            nil -> total
          end
      end
    end)
  end

  @doc "Queue length per store process, for GET /health."
  def detail do
    for name <- store_processes(),
        pid = Process.whereis(name),
        pid != nil,
        {:message_queue_len, n} <- [Process.info(pid, :message_queue_len)],
        into: %{},
        do: {inspect(name), n}
  end

  defp store_processes, do: @named
end
