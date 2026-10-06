defmodule EzthrottleLocalWeb.HealthController do
  use EzthrottleLocalWeb, :controller

  def index(conn, _params) do
    base = %{
      status: if(EzthrottleLocal.Lifecycle.draining?(), do: "draining", else: "ok"),
      l8_protocol: EzthrottleLocal.L8.version(),
      l8_public_key: EzthrottleLocal.L8.pub_b64(),
      admission: EzthrottleLocal.Admission.snapshot(),
      queues: EzthrottleLocal.AccountQueueRegistry.node_queue_snapshot(),
      pools: EzthrottleLocal.PoolRegistry.snapshot(),
      websocket: EzthrottleLocal.WebSocketQueue.snapshot()
    }

    # Only present when drain mode is enabled -- an instance that never
    # turned it on shouldn't see a new key appear here.
    body =
      case EzthrottleLocal.AccountQueueRegistry.drain_snapshot() do
        nil -> base
        drain -> Map.put(base, :drain, drain)
      end

    json(conn, body)
  end

  @doc "Readiness for load balancers: 503 with the draining headers once shutdown starts."
  def ready(conn, _params) do
    if EzthrottleLocal.Lifecycle.draining?() do
      EzthrottleLocalWeb.NodeDraining.reject(conn)
    else
      json(conn, %{status: "ready"})
    end
  end
end
