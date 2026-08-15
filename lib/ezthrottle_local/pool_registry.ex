defmodule EzthrottleLocal.PoolRegistry do
  @moduledoc """
  Top-level registry for Pool GenServers, one per pool_id, spawned on
  demand -- mirrors AccountQueueRegistry's pattern for UrlActors, and
  Aquifer's PoolRegistry (pool.go) in Go.
  """

  use GenServer

  alias EzthrottleLocal.Pool

  @table :pools

  # ---- Public API ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Registers or refreshes (heartbeats) a member of a pool, spawning the pool if it doesn't exist yet."
  @spec register(String.t(), String.t(), String.t(), float(), non_neg_integer()) :: :ok
  def register(pool_id, member_id, address, declared_rps, heartbeat_interval_ms) do
    pid = get_or_create(pool_id)
    Pool.register(pid, member_id, address, declared_rps, heartbeat_interval_ms)
  end

  @doc """
  Returns the pid for a pool's GenServer, spawning an empty one if nobody
  has registered to it yet. A job dispatched to a pool that exists but has
  zero members is a different, correctly-handled state (fails cleanly
  with "no pool members registered") from a job that isn't pool-backed at
  all -- always returning a real pid here keeps that distinction, instead
  of letting a pool-backed job silently fall through to non-pool dispatch
  with no URL, which is the exact bug this lazy-create fixed in Aquifer's
  Go implementation.
  """
  @spec get_or_create(String.t()) :: pid()
  def get_or_create(pool_id) do
    case :ets.lookup(@table, pool_id) do
      [{^pool_id, pid}] -> pid
      [] -> GenServer.call(__MODULE__, {:get_or_create, pool_id})
    end
  end

  @spec snapshot() :: map()
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {id, pid} ->
      {id, %{members: Pool.snapshot(pid), total_capacity_rps: Pool.total_capacity(pid)}}
    end)
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_or_create, pool_id}, _from, state) do
    case :ets.lookup(@table, pool_id) do
      [{^pool_id, pid}] ->
        {:reply, pid, state}

      [] ->
        {:ok, pid} = Pool.start_link(pool_id)
        Process.monitor(pid)
        :ets.insert(@table, {pool_id, pid})
        {:reply, pid, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {:_, pid})
    {:noreply, state}
  end
end
