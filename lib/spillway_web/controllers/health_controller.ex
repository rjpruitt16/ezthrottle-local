# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule SpillwayWeb.HealthController do
  use SpillwayWeb, :controller

  def index(conn, _params) do
    base = %{
      status: if(Spillway.Lifecycle.draining?(), do: "draining", else: "ok"),
      l8_protocol: Spillway.L8.version(),
      l8_public_key: Spillway.L8.pub_b64(),
      admission: Spillway.Admission.snapshot(),
      queues: Spillway.AccountQueueRegistry.node_queue_snapshot(),
      pools: Spillway.PoolRegistry.snapshot(),
      websocket:
        Map.merge(
          Spillway.WebSocketQueue.snapshot(),
          Spillway.WebSocketStore.budget_snapshot()
        )
    }

    # Only present when drain mode is enabled -- an instance that never
    # turned it on shouldn't see a new key appear here.
    body =
      case Spillway.AccountQueueRegistry.drain_snapshot() do
        nil -> base
        drain -> Map.put(base, :drain, drain)
      end

    json(conn, body)
  end

  @doc "Readiness for load balancers: 503 with the draining headers once shutdown starts."
  def ready(conn, _params) do
    if Spillway.Lifecycle.draining?() do
      SpillwayWeb.NodeDraining.reject(conn)
    else
      json(conn, %{status: "ready"})
    end
  end
end
