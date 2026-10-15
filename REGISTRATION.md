# External registration

**Off by default.** A normal deployment (a single long-lived node, or static domain/tenant
partitioning as described in [README.md](README.md#deployment-model)) is completely unaffected unless
you explicitly turn this on — no background process runs, no added overhead, nothing about default
behavior changes.

When `SPILLWAY_REGISTRY_URL` is set, this node periodically reports its own listening port to that
URL — so an external control plane (Canalis, or anything else someone builds against the same contract)
can assign tenants to it. Generic on purpose: this node has no idea what's on the other end, and doesn't
need to — it's a webhook target, delivered through the same retrying, L8-signed path drain mode's ledger
flush already uses. Mirrors Aquifer's registration.go feature-for-feature.

**Only the port is reported, not a full address.** Whatever receives the ping already sees the real
source IP on the connection itself — a self-reported address would just be redundant with that, and
less trustworthy (this node claiming its own reachable address is a weaker guarantee than the
receiver's own connection telling it directly).

**This node does not decide who gets assigned where.** That orchestration — assignment, scaling, the
whole control-plane layer — is entirely up to whatever service receives these pings. This node only
reports that it exists and is reachable.

**Env vars:**

| Var | Default | Notes |
|---|---|---|
| `SPILLWAY_REGISTRY_URL` | *(none)* | The real gate — unset means the process never starts (see application.ex). |
| `SPILLWAY_REGISTRY_INTERVAL_SECONDS` | `15` | How often to ping. Pings once immediately on start too, so a freshly-booted node doesn't sit unregistered for the first interval. |
| `PORT` | `4000` | Already read elsewhere (the port this node itself listens on) — reused here rather than introducing a second way to say the same thing. |
| `SPILLWAY_REGISTRY_RESERVED_FOR` | *(none)* | A `user_id` this instance is dedicated to. Reported as `reserved_for`; a control plane should route only that user here and never hand the instance to anyone else. |
| `SPILLWAY_REGISTRY_POOLS` | *(none)* | Comma-separated pools this node joins, e.g. `gpu,eu`. Reported as `pools`; a control plane like Canalis only sends it requests for those pools. None means the `default` pool. Every ping carries the current list. |
| `SPILLWAY_REGISTRY_ROLE` | *(none)* | What kind of traffic this instance is for, e.g. `http` or `ws` (lowercased). Reported as `role`; lets a control plane send WebSocket and HTTP traffic to instances dedicated to each. |

**Ping payload:**

```json
{
  "port": "4000",
  "state": "active",
  "reported_at": "2026-09-03T22:00:00Z",
  "reserved_for": "acme",
  "role": "http",
  "pools": ["gpu", "eu"],
  "drain_state": "unassigned",
  "fullness": 35
}
```

`fullness` is how full this node is, `0`–`100`: the same number as the `X-Aqueduct-Fullness` response header (see [API.md](API.md)), so a control plane knows before sending a node anything.

`reserved_for`, `role` and `pools` are only present when their env vars are set. `drain_state` is only present when drain mode is enabled ([DRAIN_MODE.md](DRAIN_MODE.md)): it's drain mode's own `active` / `draining` / `unassigned`, kept separate from `state` because drain mode's "draining" means "finishing one tenant's burst", not "shutting down". Reaching `unassigned` sends a ping right away instead of waiting for the next heartbeat, since that's the control plane's cue to hand this instance to someone else.

`state` is `active`, `draining`, or `offline`, the same contract as Aquifer's. Normal heartbeats report `active`. When shutdown starts (see `Spillway.Lifecycle`), Spillway immediately sends `draining` so the control plane can stop assigning new work, then makes one best-effort `offline` report after accepted work has drained. Receivers should still expire nodes that stop heartbeating, because an abrupt termination can send neither.
