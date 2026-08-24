defmodule EzthrottleLocalWeb.HealthController do
  use EzthrottleLocalWeb, :controller

  def index(conn, _params) do
    base = %{
      status: "ok",
      l8_protocol: "0.1",
      l8_public_key: EzthrottleLocal.L8.pub_b64(),
      admission: EzthrottleLocal.Admission.snapshot(),
      pools: EzthrottleLocal.PoolRegistry.snapshot()
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
end
