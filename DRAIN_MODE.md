# Drain mode

**Off by default.** A normal deployment (a single long-lived node, or static domain/tenant
partitioning) is completely unaffected unless you explicitly turn this on — no background check
runs, no added overhead, nothing about default behavior changes.

EZThrottle Local's idempotency store exists to dedupe retries while a burst is actively draining, not
to be a permanent system of record. Drain mode is for a specific deployment pattern: instances get
handed to a tenant, absorb and drain their burst, then get freed for reassignment to a different
tenant. When enabled, and this node goes completely idle (no requests anywhere on the whole node, not
just one tenant's queue) for `EZTHROTTLE_DRAIN_TIMER_SECONDS`, it flushes everything it's deduped
since the last flush to a webhook, and only on confirmed delivery, clears its local ledger — making
the node safe to hand to someone else.

For longer-running assignments, drain mode can also stream acknowledged ledger batches before the
node is idle. Batch streaming records each completed or failed user job in a small Mnesia journal,
posts bounded chunks to the same webhook, and deletes only the acknowledged journal events. The hot
idempotency/job tables stay in place until the normal idle handoff succeeds.

**EZThrottle Local does not decide who gets a freed instance next**, and does not retain the ledger
itself beyond the next flush. That orchestration — durable long-term storage, and assigning tenants to
instances — is entirely up to whatever service you build to receive this webhook. EZThrottle Local
only detects idle and hands off what it has.

**[canalis-rs](https://github.com/rjpruitt16/canalis-rs) is a real example of that orchestrator, and of
why draining to a genuinely stateless handoff is worth building.** A freed node carries no memory of
who it served last, so canalis-rs can hand it to any tenant currently waiting — durably queuing that
tenant's work in Valkey if none is free yet — without needing this node recreated or reconfigured
first. Scaling the fleet becomes adding or removing interchangeable nodes, not reprovisioning
per-tenant ones.

**State machine**, visible via `GET /health` (`"drain": {"state": "..."}`, only present when enabled):

| State | Meaning |
|---|---|
| `active` | At least one upstream domain has live work. Normal state, drain mode enabled or not. |
| `draining` | Every upstream has gone idle, but either the drain timer hasn't elapsed yet or a flush attempt is in flight/being retried. Not yet safe to hand off. |
| `unassigned` | The ledger was flushed (or there was nothing to flush) and local state is clear — safe to hand off. Reverts to `active` the instant new work arrives. |

`unassigned` is a status label, not an access gate — EZThrottle Local keeps accepting new jobs in
every state. Nothing stops a job from landing on a node mid-handoff; if your orchestrator needs a hard
guarantee that never happens, enforce it on your own end before routing traffic there.

**Env vars:**

| Var | Default | Notes |
|---|---|---|
| `EZTHROTTLE_DRAIN_ENABLED` | `false` | The real gate — the other two vars are only read when this is `true`. |
| `EZTHROTTLE_DRAIN_TIMER_SECONDS` | `45` | How long the whole node must be idle before flushing. Deliberately separate from the per-tenant-queue self-teardown timer below (`@idle_timeout_ms`) — but drain mode's own countdown only starts once every AccountQueue and UrlActor has already self-torn-down via that timer, so a real drain flush is gated by both. |
| `EZTHROTTLE_DRAIN_WEBHOOK_URL` | *(none)* | Required if enabled — if unset, drain mode logs a warning and stays off rather than flushing with nowhere to send it. |
| `EZTHROTTLE_DRAIN_BATCH_ENABLED` | `false` | Periodically stream terminal ledger events while the node is still assigned. Requires drain mode and the same webhook URL. |
| `EZTHROTTLE_DRAIN_BATCH_INTERVAL_SECONDS` | `60` | How often to attempt one batch flush when batch streaming is enabled. |
| `EZTHROTTLE_DRAIN_BATCH_MAX_EVENTS` | `1000` | Maximum unacknowledged terminal events to include in one batch webhook. |
| `EZTHROTTLE_IDLE_TIMEOUT_MS` | `300000` (5min) | The per-tenant-queue self-teardown timer itself (`@idle_timeout_ms`) — AccountQueue uses it directly; UrlActor tears itself down immediately once its last AccountQueue is gone, so this is the one real wait that gates a drain flush. Exists mainly so contract tests don't have to burn real minutes to prove one — leave this at the default in production. |

**Webhook payload:**

```json
{
  "event": "instance_idle",
  "flushed_at": "2026-08-23T14:02:11Z",
  "ledger": [
    { "idempotent_key_hash": "3fa9c1...", "job_id": "a3f9...", "status": "completed" }
  ]
}
```

When batch streaming is enabled, periodic batches use the same `ledger` entry shape plus local
sequence metadata:

```json
{
  "event": "ledger_batch",
  "batch_id": "101-250",
  "sequence_start": 101,
  "sequence_end": 250,
  "flushed_at": "2026-08-23T14:01:00Z",
  "ledger": [
    {
      "sequence": 101,
      "idempotent_key_hash": "3fa9c1...",
      "job_id": "a3f9...",
      "status": "completed",
      "recorded_at": 1798053642000
    }
  ]
}
```

The webhook response is the acknowledgement: a successful delivery deletes events through
`sequence_end`; a failed delivery leaves them in Mnesia for retry. Sequence numbers are local to one
node and are for acknowledgement only, not global identity. Downstream dedupe should still key on
`idempotent_key_hash`.

`idempotent_key_hash` is `sha256(user_id + ":" + idempotent_key)`, hex-encoded lowercase — the exact
hash this store already computes internally, never the plaintext key. A downstream consumer
re-checking a key for a duplicate must hash it the same way.

If you're also running [Aquifer](https://github.com/rjpruitt16/aquifer), its drain mode hashes the
identical way — both systems share one hash-key namespace for the same `(user_id, idempotent_key)`
pair, so a downstream consumer can hash lookups the same way regardless of which system a given
ledger entry came from.
