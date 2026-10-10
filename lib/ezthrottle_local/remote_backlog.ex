defmodule EzthrottleLocal.RemoteBacklog do
  @moduledoc """
  A cached view of other nodes' account-queue backlogs.

  Fair admission and the aggregate-budget check need every queue's backlog
  for an upstream, cluster-wide. Asking each remote queue with a
  `GenServer.call` puts the slowest node on every intake path: one paused
  or overloaded node (GC storm, noisy neighbour, SIGSTOP) stalls admission
  on every node, for as long as its calls take to time out.

  Instead, every 500ms this process makes one bounded RPC per peer node
  that reads that node's backlog counters from ETS (no queue mailbox
  involved) and caches the result here. Callers read the cache without
  blocking. A node that doesn't answer in time keeps its last known values,
  so admission degrades to slightly stale numbers instead of stalling.
  """
  use GenServer

  alias EzthrottleLocal.AccountQueue

  @table :ez_remote_backlog
  @interval_ms 500
  @rpc_timeout_ms 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached backlog of a queue on another node: `{:ok, n}` or `:unknown`."
  def lookup(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, backlog}] -> {:ok, backlog}
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh(Node.list())
    schedule()
    {:noreply, state}
  end

  @doc false
  def refresh([]), do: :ok

  def refresh(nodes) do
    nodes
    |> Task.async_stream(
      # Caught inside the task: tasks are linked to this process, so an
      # uncaught erpc timeout from a paused node would crash the cache, and
      # repeated crashes would take the supervisor (and the node) down.
      fn node ->
        try do
          {node, :erpc.call(node, AccountQueue, :local_backlogs, [], @rpc_timeout_ms)}
        catch
          _kind, _reason -> {node, :unreachable}
        end
      end,
      timeout: @rpc_timeout_ms + 200,
      on_timeout: :kill_task,
      max_concurrency: max(length(nodes), 1)
    )
    |> Enum.each(fn
      {:ok, {node, backlogs}} when is_list(backlogs) -> store(node, backlogs)
      _unreachable_or_slow -> :ok
    end)
  catch
    _kind, _reason -> :ok
  end

  defp store(node, backlogs) do
    :ets.insert(@table, backlogs)
    live = MapSet.new(backlogs, fn {pid, _} -> pid end)

    @table
    |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid ->
      if node(pid) == node and not MapSet.member?(live, pid), do: :ets.delete(@table, pid)
    end)
  end

  defp schedule, do: Process.send_after(self(), :refresh, @interval_ms)
end
