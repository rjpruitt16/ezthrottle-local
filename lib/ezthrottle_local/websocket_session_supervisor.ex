defmodule EzthrottleLocal.WebSocketSessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias EzthrottleLocal.WebSocketSession

  @registry EzthrottleLocal.WebSocketSessionRegistry

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def get_or_start(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {WebSocketSession, opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
