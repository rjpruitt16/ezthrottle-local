# EZThrottle Local

**Increase your rate limit without DDoSing your backend.**

EZThrottle Local is a self-hosted, agent-native load balancer for internal API traffic. It absorbs bursts into a durable, Mnesia-backed queue, dispatches at a controlled rate, and spreads traffic across a pool of registered backend instances. Your API can dynamically slow EZThrottle down with `X-Aqueduct-*` response headers, so an overloaded service can shed pressure before it starts returning 429s.

Kubernetes and modern orchestrators are great at scaling compute — but they were not designed for spiky traffic or tenant fairness. When a burst of agentic requests arrives, your pods get hammered, queues back up unevenly, and noisy tenants crowd out everyone else. Horizontal scaling helps eventually, but the spike hits before a new pod is ready.

Real numbers on durability, throughput ceiling, admission shedding, multi-tenant fairness, and a [real GPU under load](benchmark.md#6-gpu-inference-and-the-retry-tax-runpodvllm) are in [benchmark.md](benchmark.md) — including a head-to-head comparison against [Aquifer](https://github.com/rjpruitt16/aquifer), the Go/SQLite sibling this project mirrors.

## How it works

```
Client → POST /jobs → EZThrottle Local → paced outbound requests → Your API
              ↓                                                          ↓
     GET /jobs/:id/stream                                        response body
              ↓                                                          ↓
     live event stream ←─────────────────────────────────────────────────
              ↓
     (or webhook if stream drops)
```

1. **Submit a job** — POST the request you want forwarded, with a `webhook_url` for the response.
2. **EZThrottle queues it** — Jobs are held in memory and dispatched at the configured RPS.
3. **Your API responds** — EZThrottle reads `X-Aqueduct-Rps`/`X-EZTHROTTLE-RPS` and `X-Aqueduct-Max-Concurrent`/`X-EZTHROTTLE-MAX-CONCURRENT` headers from the response and adjusts pace automatically. `X-Aqueduct-*` is read first if both are present — the shared protocol namespace also spoken by [Aquifer](https://github.com/rjpruitt16/aquifer), so a backend already emitting Aqueduct headers works against either implementation unchanged. For backends that speak neither namespace but already report load some other way, EZThrottle falls back to [ORCA](https://github.com/cncf/xds/blob/main/xds/data/orca/v3/orca_load_report.proto) — vLLM supports this natively: EZThrottle sends `endpoint-load-metrics-format: TEXT` on every dispatch, and a response carrying an `endpoint-load-metrics` header with `kv_cache_usage_perc` is used to pace down (full rate below 70% utilization, 2 RPS at 70-90%, 0.5 RPS at 90-97%, 0.25 RPS above that) only when no explicit Aqueduct/EZThrottle header is present.
4. **Stay on the line or hang up** — open `GET /jobs/:id/stream` to receive live events as the job moves through the queue, or disconnect and the result is delivered to your `webhook_url` when ready.

## Per-tenant fairness (AccountQueue mode)

By default all traffic for a destination flows through one shared queue. Isolation can be turned on two ways:

**By your API's response** — respond to a dispatched request with:

```
X-Aqueduct-Account-Queue: enabled
```

(or `X-EZTHROTTLE-ACCOUNT-QUEUE: enabled` — both are read, `X-Aqueduct-*` first if both are present)

**By the client submitting the job** — set the same header on the `POST /jobs` request itself, if you already know at submission time that this tenant needs isolation:

```
X-Aqueduct-Account-Queue: enabled
```

Either way, EZThrottle switches to per-user isolation — each `user_id` + API key gets its own queue. A heavy user no longer blocks everyone else.

Critically, each user can run at a **different pace**. If your service processes requests from user A faster than user B — because of their tier, their data size, or just load at that moment — each user's queue drains independently at the rate their own responses signal back. A premium user responding with `X-Aqueduct-Rps: 50` runs at 50 RPS while a free-tier user on `X-Aqueduct-Rps: 2` runs at 2, in parallel, without either affecting the other. Note that literal pace (RPS/max-concurrent) can only ever be set by the upstream's own response headers — never by the client submitting the job — so a client can ask for isolation but never for a faster rate than what's configured.

Disable it any time by responding with `X-Aqueduct-Account-Queue: disabled`.

Each tenant's own pace is still capped by the upstream's actual budget, though — a background check keeps the *sum* of every active tenant queue's rate within the upstream's configured (or, for a pool-backed upstream, live aggregate) ceiling, throttling proportionally if too many tenants are active at once. Isolation between tenants doesn't mean each one gets its own unbounded copy of the full rate.

Long-term protocol goal: if more services emit `X-Aqueduct-*`, agents can respond to capacity signals instead of independently guessing retry and concurrency behavior. EZThrottle works today without ecosystem adoption; broader protocol adoption is the longer-term goal.

**Webhook delivery uses this same pacing, not a separate fire-and-forget path.** A webhook POST is enqueued as its own job, keyed by the receiver's domain, and dispatched through the identical AccountQueue machinery described above — so a webhook receiver can slow EZThrottle down with `X-Aqueduct-Rps`/`X-Aqueduct-Max-Concurrent` response headers exactly the way a real upstream can, instead of just getting hammered on a fixed retry schedule. It's also crash-durable: a webhook still pending when the node restarts is recovered and retried the same way a queued job is. Retries trigger on `5xx` responses, up to 4 attempts with exponential backoff (1s · 2s · 4s · 8s). Drain mode's own ledger-flush webhook is unaffected — it stays synchronous, confirming delivery before clearing the local idempotency ledger.

---

## Agent-native load balancing

Instead of dispatching to a fixed `url`, a job can target a named **pool** — a group of registered service instances EZThrottle picks from at dispatch time. Useful when you have several interchangeable backends (or, e.g., a separate group of writers and a separate group of readers) instead of one fixed endpoint. Ported from [Aquifer](https://github.com/rjpruitt16/aquifer)'s Go implementation, built and proven out there first.

**Registering a member:**

```bash
curl -X POST https://your-ezthrottle/pools/writers/members \
  -d '{"member_id": "writer-1", "address": "http://10.0.1.5:8080", "capacity_rps": 20, "heartbeat_interval_seconds": 30}'
```

The same call is both initial registration and heartbeat — call it again periodically (at roughly your declared `heartbeat_interval_seconds`) to stay in the pool. Missing several consecutive expected heartbeats evicts a member. A member can register under more than one pool id.

**Dispatching to a pool:**

```json
{
  "user_id": "user-123",
  "idempotent_key": "job-1",
  "pool_id": "writers",
  "method": "POST",
  "webhook_url": "https://yourapp.com/webhooks/ezthrottle"
}
```

`pool_id` and `url` are mutually exclusive — a job sets exactly one.

**How a member gets picked:** proportional to `capacity_rps × reputation`, not equal-split round robin — a member declaring 100 RPS gets roughly 4x the dispatches of one declaring 25. The pool's aggregate ceiling is the live sum of every member's current effective rate, so it grows and shrinks automatically as members register, degrade, or drop out — no need to reconfigure EZThrottle as your fleet autoscales.

**Reputation**: a dispatch failure halves a member's effective share; a success nudges it back up. A member isn't evicted on one bad response — only once its reputation has stayed at the floor continuously, with no interrupting success, for a sustained window. This avoids flapping a member in and out of the pool over a single transient error.

**Set `capacity_rps` conservatively, not at your true theoretical max.** EZThrottle only learns a member died via a failed dispatch or a missed heartbeat, both of which lag the actual failure — leaving headroom in what you declare gives real slack for that detection delay. Reputation decay is a second line of defense on top of this.

**A given `pool_id` should belong to exactly one EZThrottle instance** — same partitioning rule as everywhere else in this README. Pool state isn't shared or coordinated across instances; if the same member registers the same `pool_id` with two different instances, each one independently believes it owns that member's full declared capacity. If a member genuinely needs to register with more than one instance, divide its declared `capacity_rps` across however many it's registered with.

`GET /health` reports every pool's current members, their declared capacity, and current reputation.

## Streaming — stay on the line or get a voicemail

Most queue systems force you to choose: poll for status or hope the webhook lands. EZThrottle gives you a third option — an open SSE stream that tells you exactly what's happening in real time.

```bash
# Submit a job
curl -X POST http://localhost:4000/jobs -d '{...}'
# → { "job_id": "abc123" }

# Stay on the line
curl -N http://localhost:4000/jobs/abc123/stream
```

```
event: queued
data: {"job_id":"abc123","status":"queued"}

event: position
data: {"job_id":"abc123","position":4}

event: position
data: {"job_id":"abc123","position":2}

event: dispatching
data: {"job_id":"abc123"}

event: completed
data: {"job_id":"abc123","response_status":200,"body":"..."}
```

**If the stream drops before completion, the result is delivered to your `webhook_url` automatically.** You never lose the response — stream for the happy path, webhook as the guaranteed fallback.

### Queue position for agent fleets

When multiple agents share the same API key, they share the same queue. The `position` event tells each agent where it stands:

```
position: 12 → the line is long, go work on something else
position: 3  → getting close, stay on the line
dispatching  → your turn
```

An agent that sees position 12 can disconnect, pick up other work, and trust the webhook will arrive when the job is done. An agent at position 1 stays on the line and streams the response as tokens arrive.

This is the same pattern TCP brought to packet delivery at Layer 4 — coordination built into the infrastructure so every client doesn't have to solve it independently. At Layer 7, for API workflows, the queue is the protocol.

## API

### Submit a job

```bash
POST /jobs
Content-Type: application/json

{
  "user_id": "user_123",
  "idempotent_key": "order-456-attempt-1",
  "url": "https://api.yourservice.com/process",
  "method": "POST",
  "headers": { "Authorization": "Bearer sk-..." },
  "body": "{\"input\": \"data\"}",
  "webhook_url": "https://yourapp.com/webhooks/results"
}
```

**Response headers your API can return to control pacing:**

| Header | Effect |
|---|---|
| `X-EZTHROTTLE-RPS: 10` | Raise or lower requests per second |
| `X-EZTHROTTLE-MAX-CONCURRENT: 5` | Change max in-flight requests |
| `X-EZTHROTTLE-ACCOUNT-QUEUE: enabled` | Switch to per-tenant queue isolation |

### Stream job events (SSE)

```bash
GET /jobs/:id/stream
```

Opens a server-sent event stream. Events: `queued`, `position`, `dispatching`, `completed`, `failed`. Keepalive pings sent every 30 seconds. If you disconnect before completion, the result is delivered to your `webhook_url`.

### Check job status

```bash
GET /jobs/:id
```

### Health check

```bash
GET /health
```

## Idempotency

Every job requires an `idempotent_key`. Submitting the same key twice **for the same `user_id`** returns the original job ID without re-executing the request — different users can safely use the same `idempotent_key` without colliding with each other. Keys expire after 24 hours (configurable). Backed by Mnesia (`disc_copies`), not ETS — durable across a crash, not just a graceful restart. See [benchmark.md](benchmark.md) for what that guarantee actually costs and how it's tuned.

**Delivery semantics:** EZThrottle provides at-least-once dispatch and webhook delivery, not exactly-once execution. If the node crashes after a dispatch succeeds but before it records that completion, the recovered job dispatches to the upstream again on restart — so it's not just the webhook that can repeat, the upstream call itself can. Make both your upstream endpoint and your webhook handler idempotent on `job_id` (or `idempotent_key`) anywhere duplicate execution isn't safe, the same contract Stripe and GitHub webhooks already ask of you.

## Durability (Mnesia)

Jobs are written to Mnesia disc-backed tables, not kept purely in memory. Two things matter for what "durable" actually means here:

- `MNESIA_DIR` — where the on-disk tables live. **Must point at a persistent volume in production** (defaults to `/data/mnesia` in `fly.toml`, mirroring Aquifer's `DB_PATH`) — without a real volume mount, this data lives on the machine's ephemeral filesystem and durability is lost on every redeploy.
- `EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS` (default `100`) — Mnesia's `disc_copies` tables live in RAM by default, with the disk copy caught up via a periodic flush, not on every write. `0` flushes synchronously on every write (zero loss, real per-request latency cost); a positive value batches the flush on a timer instead, bounding the loss window on a true crash to roughly that many milliseconds of writes. 100ms was found empirically to be a good default — see [benchmark.md](benchmark.md) for why going higher made things *worse*, not better.

## Drain mode

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

**EZThrottle Local does not decide who gets a freed instance next**, and does not retain the ledger
itself beyond the next flush. That orchestration — durable long-term storage, and assigning tenants to
instances — is entirely up to whatever service you build to receive this webhook. EZThrottle Local
only detects idle and hands off what it has.

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
| `EZTHROTTLE_DRAIN_TIMER_SECONDS` | `45` | How long the whole node must be idle before flushing. Deliberately separate from the unrelated 5-minute per-tenant-queue self-teardown timer (`@idle_timeout_ms`), which reclaims one queue's process and has nothing to do with node-wide handoff. |
| `EZTHROTTLE_DRAIN_WEBHOOK_URL` | *(none)* | Required if enabled — if unset, drain mode logs a warning and stays off rather than flushing with nowhere to send it. |

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

`idempotent_key_hash` is `sha256(user_id + ":" + idempotent_key)`, hex-encoded lowercase — the exact
hash this store already computes internally, never the plaintext key. A downstream consumer
re-checking a key for a duplicate must hash it the same way.

If you're also running [Aquifer](https://github.com/rjpruitt16/aquifer), its drain mode hashes the
identical way — both systems share one hash-key namespace for the same `(user_id, idempotent_key)`
pair, so a downstream consumer can hash lookups the same way regardless of which system a given
ledger entry came from.

## Admission control

Memory/DB-size ceilings that shed new (non-duplicate) jobs with a `429` once exceeded, mirroring [Aquifer's](https://github.com/rjpruitt16/aquifer) admission control:

| Env var | Default | Description |
|---|---|---|
| `EZTHROTTLE_MEMORY_LIMIT_MB` | *(disabled)* | Reject new jobs once BEAM's total memory exceeds this many MB |
| `EZTHROTTLE_MAX_BODY_BYTES` | `1048576` (1MB) | Reject oversized request bodies with `413` |
| `EZTHROTTLE_DB_MAX_BYTES` | `838860800` (800MB) | Reject new jobs once the Mnesia directory exceeds this many bytes |
| `EZTHROTTLE_RETRY_AFTER_SECONDS` | `5` | Base `Retry-After` on a `429` — doubles per consecutive rejection (capped at 60s), resets the moment a request is allowed again |

Body-size and DB-size admission are **on by default**, sized off the infrastructure this project is
actually benchmarked against (a single 512MB Fly.io instance with a 1GB volume — see
[benchmark.md](benchmark.md)); set an explicit `0` to disable a check, or raise it for a bigger
deployment. Memory is the exception — there's no safe one-size-fits-all default since it depends on
your own deployment's memory budget, so it stays disabled until set explicitly; EZThrottle logs a
warning on startup if it isn't (benchmarked safe at 400MB on a 512MB instance, as a starting point).
`GET /health` reports a live `admission` snapshot.

## Configuration

```elixir
# config/runtime.exs
config :ezthrottle_local,
  default_rps: 2.0,
  account_queue_enabled: false,   # opt-in per-tenant isolation
  idempotent_ttl: 86_400,         # seconds
  metrics_adapter: MyApp.Metrics  # optional; defaults to no-op
```

### Metrics adapter

EZThrottle Local emits lifecycle events through a configurable metrics adapter.
Adapters implement the `EzthrottleLocal.Metrics` behaviour:

```elixir
defmodule MyApp.Metrics do
  @behaviour EzthrottleLocal.Metrics

  def job_queued(user_id, upstream), do: :ok
  def job_dispatched(user_id, upstream), do: :ok
  def job_completed(user_id, upstream, duration_ms), do: :ok
  def job_failed(user_id, upstream, reason), do: :ok
  def webhook_delivered(url, attempt), do: :ok
  def webhook_failed(url, attempts), do: :ok
  def queue_depth(upstream, depth), do: :ok
  def flow_rate(upstream, rps), do: :ok
end
```

The default adapter is `EzthrottleLocal.Metrics.Noop`, so existing deployments do not change.

## L8 Protocol — trustless webhook delivery

Traditional webhook security shares a secret between sender and receiver, stored in a database on both sides — something that can be stolen, logged by accident, or forgotten to rotate, letting anyone forge deliveries silently once it leaks. EZThrottle Local implements **L8 v0.1**, a lightweight challenge-response protocol that replaces the shared secret with Ed25519 public key cryptography — there's no secret to steal from a database.

**How it works:**

1. Your webhook receiver publishes a public key at `GET /.well-known/l8`
2. Before the first delivery, EZThrottle challenges the receiver to prove ownership of the corresponding private key — a one-time handshake per domain
3. Trust is cached to disk as `l8-trust/{domain}.json` — the handshake never runs again for that domain
4. Every delivery carries `X-L8-Signature` headers, verified locally with a single Ed25519 call — no database lookup, no round-trip to any authority, microseconds

Trust stays deliberately pairwise, not transitive, by design. For better security and less latency than a shared-secret scheme, see the [L8 spec](https://rjpruitt16.github.io/l8-protocol/) for the full protocol rationale — the same canonical spec [Aquifer](https://github.com/rjpruitt16/aquifer) follows.

Set `L8_PRIVATE_KEY` (base64 Ed25519 private key) for a stable identity across restarts, or let EZThrottle auto-generate one on first start. Delete `l8-trust/{domain}.json` to revoke trust with a domain — the handshake re-runs on next delivery.

**EZThrottle exposes:**

| Endpoint | Purpose |
|---|---|
| `GET /.well-known/l8` | EZThrottle's public key — receivers discover it here |
| `POST /l8/challenge` | Handles incoming challenges from receivers verifying EZThrottle's identity |
| `GET /l8-spec` | Full L8 protocol spec, served locally for an agent/script with only network access to this instance |

**Graceful degradation:** L8 is opt-in. If a receiver doesn't implement `/.well-known/l8`, delivery proceeds unsigned — receivers that don't support L8 are completely unaffected.

---

## Running locally

```bash
mix setup
mix phx.server
```

Integration tests (requires `hurl` and Python 3 with Flask):

```bash
make integration-test
```

L8 protocol tests (verifies handshake, signed delivery, and cryptographic signature — requires `pip install cryptography`):

```bash
make l8-test
```

## Docker

```bash
docker build -t ezthrottle-local .
docker run -p 4000:4000 ezthrottle-local
```

## Do not expose this directly to untrusted callers

`POST /jobs` takes a `url` field and dispatches a real HTTP request to it. If an arbitrary or untrusted party can set that field, EZThrottle becomes an open relay/SSRF vector — it can be pointed at your internal network, cloud metadata endpoints (`169.254.169.254`), or anything else the machine it runs on can reach, using its own network position and identity. The intended caller is **your own trusted backend or gateway code**, dispatching to a specific microservice or third-party API it already knows about — not an agent, end user, or any other untrusted party choosing the destination itself. Run it on a private network or internal service mesh, not bound to a public address, and if agents need to reach it, put your own authorization and destination allow-listing in front rather than letting them call this API directly.

## Deploy to Fly.io

```bash
fly launch --config fly.toml
fly volumes create ezthrottle_data --region iad --size 1
fly deploy
```

The volume is required now that jobs are Mnesia-backed (`disc_copies`), not pure ETS — without it, `MNESIA_DIR` lives on the machine's ephemeral filesystem and durability is lost on every redeploy.

For maximum queue capacity, use the largest available machine. A 32GB RAM machine can hold 3–32 million jobs in memory — enough buffer for hours of traffic at typical agentic workloads, giving your autoscaler time to catch up before a single request is dropped.

```toml
[[vm]]
  memory = "32gb"
  cpu_kind = "performance"
  cpus = 16
```

## Deploy to Kubernetes

A fourth deployment shape alongside sidecar, standalone, and embedded library: EZThrottle Local as a normal Deployment, reached through a Gateway API proxy (Envoy Gateway) instead of a sidecar. See [`examples/kubernetes/`](examples/kubernetes/) — verified end-to-end against a real `kind` cluster, including a real pod restart proving Mnesia durability survives it (requires a stable `RELEASE_NODE`, documented there).

## Scaling by partitioning

Each node persists to its own Mnesia directory — no external database or coordination service to run, and no shared state between nodes. Scale by partitioning: run one node per upstream domain or tenant, each owning a distinct key space, and total throughput scales with node count. Multiple nodes against the *same* upstream without partitioning multiplies your request rate against it instead — the one setup to avoid. The same applies to pools: a given `pool_id` should belong to exactly one node, since pool state isn't shared across nodes (see the pool-registration note above).

This partitioning is static — decided at deploy time, fixed until you redeploy. [Drain mode](#drain-mode) is a dynamic alternative to the same problem: rather than every node owning a fixed slice forever, an idle node can flush what it's deduped and hand itself back for reassignment, letting an external orchestrator repartition on the fly as load shifts between tenants instead of you doing it by hand at deploy time. The two aren't mutually exclusive — a fleet can partition statically by upstream domain while individual nodes within a partition cycle through tenants dynamically via drain mode. This mirrors [Aquifer's](https://github.com/rjpruitt16/aquifer) identical guidance.

## Zero-downtime updates

EZThrottle Local is built on the BEAM (Erlang VM), which supports hot code reloading. Updates to rate limiting logic, routing behavior, or configuration can be deployed to a running node without restarting the process — the in-memory queue is preserved across deploys and no jobs are lost.

## EZThrottle Cloud

EZThrottle Local is a single node: jobs are durable to disk (survives a crash or restart of that machine — see [benchmark.md](benchmark.md)) and webhook delivery already retries with backoff, but there's no cross-machine or cross-region replication — if the machine itself is destroyed (not just restarted) before its volume can be recovered, or the whole region goes down, that's outside what a single node can promise.

**[EZThrottle Cloud](https://ezthrottle.network)** handles the cases this cannot:

- **Multi-step workflows** — chain dependent API calls with conditional branching
- **Cross-region durability** — jobs survive not just a node restart but a full region failure
- **Regional delivery guarantee** — if a region is healthy, your job will be delivered, with dead-letter queues for visibility when it isn't
- **Internal + external traffic** — protect both your own services and third-party APIs from the same control plane
- **Distributed fairness** — per-tenant rate limiting across multiple nodes and regions

EZThrottle Local is the right tool for teams that want to get started immediately with zero infrastructure. When you need durability and cross-region guarantees, EZThrottle Cloud picks up where this leaves off.

## Writing

- [Eliminate GPU Waste by Cutting the Retry Tax](https://rahmipruitt.me/content/gpu-retry-tax/) — the thesis behind [drain mode](#drain-mode) and the ORCA fallback pacing [GPU benchmark](benchmark.md#6-gpu-inference-and-the-retry-tax-runpodvllm) above.
- [GitHub Outages Show the Limits of Reactive Scaling](https://rahmipruitt.me/content/github-outage-reactive-scaling/) — why reactive scaling and retry storms don't mix, the problem EZThrottle Local absorbs instead.
