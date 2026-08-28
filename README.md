# EZThrottle Local

**Increase your rate limit without DDoSing your backend.**

Kubernetes and modern orchestrators are great at scaling compute — but they weren't designed for spiky traffic or tenant fairness. When a burst of requests arrives, your pods get hammered, queues back up unevenly, and one noisy tenant crowds out everyone else. Horizontal scaling helps eventually, but the spike hits before a new pod is ready, so the burden falls on clients retrying uncoordinated — [wasted utilization and higher cost](https://rahmipruitt.me/content/gpu-retry-tax/) on one end, [outages reactive autoscaling alone can't prevent](https://rahmipruitt.me/content/github-outage-reactive-scaling/) on the other.

EZThrottle Local is what I built to actually fix it: a self-hosted load balancer that absorbs bursts into a durable queue, dispatches at a controlled rate, and spreads traffic across a pool of backend instances — your API sheds load by talking back, not by getting hammered until it falls over.

Real numbers — durability, throughput ceiling, admission shedding, multi-tenant fairness, a real GPU under load — are in [benchmark.md](benchmark.md), including a head-to-head against [Aquifer](https://github.com/rjpruitt16/aquifer), the Go/SQLite sibling this project mirrors.

---

## Use cases

**Protect your API**
```
agents / clients  →  POST /jobs to EZThrottle  →  your backend (at controlled RPS)
```
Agents or clients hammering your API over HTTP? EZThrottle queues their requests and drains them to your backend at a pace it can handle. Your backend returns `X-Aqueduct-Rps` headers to signal how fast it wants traffic in real time.

**A durable checkpoint in front of a rate-limited resource**
```
your app  →  POST /jobs to EZThrottle  →  database / CI runner / OpenAI / Stripe / any rate-limited API
```
Calling something with its own capacity limit — a database read replica, a CI runner, a third-party API? EZThrottle queues the calls durably and dispatches them at your configured rate, so a burst from your own side never becomes the thing that takes the downstream down. Works especially well closed-loop: if the downstream already speaks `X-Aqueduct-*` headers, it can tell EZThrottle to back off in real time instead of you guessing a static rate.

**Edge load balancer → gateway — pace and route at the edge**
```
your users  →  POST /proxy to EZThrottle  →  your resources (paced, routed, at the speed you can handle)
```
Point EZThrottle at your resources like a normal reverse proxy, close to the caller. It tries the request directly first — a healthy resource sees no queue at all — and only falls back to durable queuing when something's actually overloaded, on the same connection. For low-latency cross-region failover on top of that: Fly.io's own [`fly-replay`](https://fly.io/docs/networking/dynamic-request-routing/) is a response header *your* app returns to tell Fly's edge "redeliver this request in a different region" — your own logic in front of EZThrottle can watch for the same overload signal the circuit breaker already uses (429, 5xx, an ORCA threshold) and respond with `fly-replay` instead of just falling back locally, rerouting at Fly's edge rather than adding a round trip through your own infrastructure. Not something EZThrottle implements itself — the same overload classification just composes naturally with it.

In all three, the upstream can lower the dispatch pace via response headers — see [Per-tenant fairness](#per-tenant-fairness-accountqueue-mode) for how the ceiling, backoff, and recovery actually work.

---

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
3. **Your API responds** — EZThrottle reads pacing headers from the response and adjusts automatically, falling back to the real [ORCA](https://github.com/cncf/xds/blob/main/xds/data/orca/v3/orca_load_report.proto) standard for backends that report load a different way (vLLM and Triton/TensorRT-LLM both work today) — see [Per-tenant fairness](#per-tenant-fairness-accountqueue-mode) below for the full header reference.
4. **Stay on the line or hang up** — open `GET /jobs/:id/stream` to receive live events as the job moves through the queue, or disconnect and the result is delivered to your `webhook_url` when ready.

---

## Per-tenant fairness (AccountQueue mode)

By default all traffic for a destination flows through one shared queue. Turn on per-tenant isolation via a response header (or set it on submission if you already know a tenant needs it) and each `user_id` + API key gets its own independently paced queue — a heavy user no longer blocks everyone else, and each tenant can run at a genuinely different pace.

<details>
<summary>Full pacing reference — headers, isolation mechanics, ORCA fallback, webhook pacing</summary>

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

`X-Aqueduct-*` is read first if both namespaces are present — the shared protocol namespace also spoken by [Aquifer](https://github.com/rjpruitt16/aquifer), so a backend already emitting Aqueduct headers works against either implementation unchanged.

**ORCA fallback**, for backends that speak neither namespace but already report load some other way: EZThrottle sends `endpoint-load-metrics-format: text` on every dispatch, and a response carrying an `endpoint-load-metrics` header is used to pace down (full rate below 70% utilization, 2 RPS at 70-90%, 0.5 RPS at 90-97%, 0.25 RPS above that) only when no explicit Aqueduct/EZThrottle header is present. Two backends verified directly against their own source: **vLLM** (metric name `kv_cache_usage_perc`, case-insensitive opt-in) and **Triton/TensorRT-LLM** (metric name `kv_cache_utilization`, case-sensitive lowercase-only opt-in — EZThrottle sends lowercase specifically so both work).

Long-term protocol goal: if more services emit `X-Aqueduct-*`, agents can respond to capacity signals instead of independently guessing retry and concurrency behavior. EZThrottle works today without ecosystem adoption; broader protocol adoption is the longer-term goal.

**Webhook delivery uses this same pacing, not a separate fire-and-forget path.** A webhook POST is enqueued as its own job, keyed by the receiver's domain, and dispatched through the identical AccountQueue machinery described above — so a webhook receiver can slow EZThrottle down with `X-Aqueduct-Rps`/`X-Aqueduct-Max-Concurrent` response headers exactly the way a real upstream can, instead of just getting hammered on a fixed retry schedule. It's also crash-durable: a webhook still pending when the node restarts is recovered and retried the same way a queued job is. Retries trigger on `5xx` responses, up to 4 attempts with exponential backoff (1s · 2s · 4s · 8s). Drain mode's own ledger-flush webhook is unaffected — it stays synchronous, confirming delivery before clearing the local idempotency ledger.

</details>

---

## Agent-native load balancing

Instead of dispatching to a fixed `url`, a job can target a named **pool** — a group of registered service instances EZThrottle picks from at dispatch time, weighted by declared capacity and live reputation. Ported from [Aquifer](https://github.com/rjpruitt16/aquifer)'s Go implementation, built and proven out there first.

<details>
<summary>Full pool reference — registration, dispatch, reputation model</summary>

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

</details>

---

## Streaming — stay on the line or get a voicemail

Most queue systems force you to choose: poll for status or hope the webhook lands. EZThrottle gives you a third option — an open SSE stream that tells you exactly what's happening in real time, or a `webhook_url` fallback if you disconnect. Coordination built into the infrastructure, the same way TCP handled it at Layer 4 — at Layer 7, for API workflows, the queue is the protocol.

<details>
<summary>Full streaming reference — event shapes, queue position for agent fleets</summary>

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

</details>

---

## API

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

**[API.md](API.md)** has the full reference: streaming events, checking job status, `POST /proxy` (edge-gateway mode — see [Use cases](#use-cases)), the health check, and the response headers your API can return to control pacing.

---

## Idempotency

Every job requires an `idempotent_key`. Submitting the same key twice **for the same `user_id`** returns the original job ID without re-executing the request — different users can safely use the same `idempotent_key` without colliding with each other. Keys expire after 24 hours (configurable). Backed by Mnesia (`disc_copies`), not ETS — durable across a crash, not just a graceful restart. See [benchmark.md](benchmark.md) for what that guarantee actually costs and how it's tuned.

**Delivery semantics:** EZThrottle provides at-least-once dispatch and webhook delivery, not exactly-once execution. If the node crashes after a dispatch succeeds but before it records that completion, the recovered job dispatches to the upstream again on restart — so it's not just the webhook that can repeat, the upstream call itself can. Make both your upstream endpoint and your webhook handler idempotent on `job_id` (or `idempotent_key`) anywhere duplicate execution isn't safe, the same contract Stripe and GitHub webhooks already ask of you.

---

## Durability (Mnesia)

Jobs are written to Mnesia disc-backed tables, not kept purely in memory.

<details>
<summary>Full durability reference — MNESIA_DIR, flush interval tuning</summary>

Two things matter for what "durable" actually means here:

- `MNESIA_DIR` — where the on-disk tables live. **Must point at a persistent volume in production** (defaults to `/data/mnesia` in `fly.toml`, mirroring Aquifer's `DB_PATH`) — without a real volume mount, this data lives on the machine's ephemeral filesystem and durability is lost on every redeploy.
- `EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS` (default `100`) — Mnesia's `disc_copies` tables live in RAM by default, with the disk copy caught up via a periodic flush, not on every write. `0` flushes synchronously on every write (zero loss, real per-request latency cost); a positive value batches the flush on a timer instead, bounding the loss window on a true crash to roughly that many milliseconds of writes. 100ms was found empirically to be a good default — see [benchmark.md](benchmark.md) for why going higher made things *worse*, not better.

</details>

---

## Partitioning strategies

Running one node for everything works fine until you have multiple tenants or multiple upstreams sharing it — then one tenant's burst, or one upstream's own rate limit, ends up affecting everyone else on that same node. Two ways to split traffic apart so that doesn't happen, not mutually exclusive:

**Static partitioning** — decided once, at deploy time: dedicate one node to a single protected resource — a CI runner, a database, a GPU, or a rate-limited external API you want to be nice to — so that resource only ever sees traffic paced the way you configured, up to whatever it can actually bear. Multiple tenants can safely share that same node: turn on [AccountQueue mode](#per-tenant-fairness-accountqueue-mode) and each tenant gets their own independently-paced queue, so one tenant's burst doesn't starve another's, and the resource itself never sees more aggregate load than it's rated for. The mistake to avoid: pointing multiple *nodes* at the *same* resource instead of routing everyone through this one pacing checkpoint — that just multiplies your total request rate against it. Same rule for pools: a given `pool_id` should belong to exactly one node, since pool state isn't shared across nodes.

**Dynamic partitioning (drain mode)** — off by default, for a more specific shape: instead of deciding every assignment up front, a node gets handed to one tenant at a time, absorbs and drains whatever burst that tenant sends, then frees itself up to be handed to a *different* tenant next — useful when you want dedicated capacity per user without hand-assigning it at deploy time. A normal single-node or statically-partitioned deployment is completely unaffected unless you turn this on. When idle for `EZTHROTTLE_DRAIN_TIMER_SECONDS`, the node flushes its deduped idempotency ledger to a webhook and clears local state, moving through an `active` → `draining` → `unassigned` state machine visible via `GET /health`. See **[DRAIN_MODE.md](DRAIN_MODE.md)** for the full state machine, env vars, and webhook payload shape.

The two combine: a fleet can partition statically by upstream domain, while individual nodes within a partition cycle through tenants dynamically via drain mode. This mirrors [Aquifer's](https://github.com/rjpruitt16/aquifer) identical guidance.

---

## Admission control

Memory/DB-size ceilings that shed new (non-duplicate) jobs with a `429` once exceeded, mirroring [Aquifer's](https://github.com/rjpruitt16/aquifer) admission control.

<details>
<summary>Full admission control reference — env vars, defaults</summary>

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

</details>

---

## Configuration

Runtime config lives in `config/runtime.exs` — default RPS, account-queue mode, idempotency TTL, and a pluggable metrics adapter.

<details>
<summary>Full configuration reference — runtime config, metrics adapter behaviour</summary>

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

</details>

---

## L8 Protocol — trustless webhook delivery

Traditional webhook security shares an HMAC secret between sender and receiver, stored in a database on both sides — something that can be stolen, logged accidentally, or forgotten during rotation, letting anyone forge deliveries forever once it leaks. EZThrottle Local implements **L8 v0.1**, a lightweight challenge-response protocol that replaces the shared secret with Ed25519 public key cryptography: the receiver publishes a public key, a one-time handshake proves both sides own their private keys, and every delivery afterward carries a signature verified locally in microseconds — no database lookup, no round-trip to any authority.

The full protocol rationale, wire format, and a reference receiver implementation live at the **[L8 spec](https://rjpruitt16.github.io/l8-protocol/)** — the same canonical spec [Aquifer](https://github.com/rjpruitt16/aquifer) follows — also served locally at `GET /l8-spec` for an agent/script with only network access to this instance. Set `L8_PRIVATE_KEY` for a stable identity across restarts, or let EZThrottle auto-generate one on first start.

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

---

## Docker

```bash
docker build -t ezthrottle-local .
docker run -p 4000:4000 ezthrottle-local
```

---

## Do not expose this directly to untrusted callers

`POST /jobs` takes a `url` field and dispatches a real HTTP request to it. If an arbitrary or untrusted party can set that field, EZThrottle becomes an open relay/SSRF vector — it can be pointed at your internal network, cloud metadata endpoints (`169.254.169.254`), or anything else the machine it runs on can reach, using its own network position and identity. The intended caller is **your own trusted backend or gateway code**, dispatching to a specific microservice or third-party API it already knows about — not an agent, end user, or any other untrusted party choosing the destination itself. Run it on a private network or internal service mesh, not bound to a public address, and if agents need to reach it, put your own authorization and destination allow-listing in front rather than letting them call this API directly.

---

## Deployment

Run one node per upstream domain or tenant — each node persists to its own Mnesia directory, no external database or coordination service required, and total throughput scales with node count.

<details>
<summary>Full deployment reference — Fly.io, Kubernetes, partitioning, zero-downtime updates</summary>

### Deploy to Fly.io

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

### Deploy to Kubernetes

A fourth deployment shape alongside sidecar, standalone, and embedded library: EZThrottle Local as a normal Deployment, reached through a Gateway API proxy (Envoy Gateway) instead of a sidecar. See [`examples/kubernetes/`](examples/kubernetes/) — verified end-to-end against a real `kind` cluster, including a real pod restart proving Mnesia durability survives it (requires a stable `RELEASE_NODE`, documented there).

### Scaling by partitioning

See [Partitioning strategies](#partitioning-strategies) above for how to assign tenants to nodes, statically or dynamically.

### Zero-downtime updates

EZThrottle Local is built on the BEAM (Erlang VM), which supports hot code reloading. Updates to rate limiting logic, routing behavior, or configuration can be deployed to a running node without restarting the process — the in-memory queue is preserved across deploys and no jobs are lost.

</details>

---

## Writing

- [Eliminate GPU Waste by Cutting the Retry Tax](https://rahmipruitt.me/content/gpu-retry-tax/) — the thesis behind [drain mode](#partitioning-strategies) and the ORCA fallback pacing [GPU benchmark](benchmark.md#6-gpu-inference-and-the-retry-tax-runpodvllm) above.
- [GitHub Outages Show the Limits of Reactive Scaling](https://rahmipruitt.me/content/github-outage-reactive-scaling/) — why reactive scaling and retry storms don't mix, the problem EZThrottle Local absorbs instead.

## License

MIT

Built by [Rahmi Pruitt](https://rahmipruitt.me) — open to AI infra consulting, founding engineer, and contract work.
