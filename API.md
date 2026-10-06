# API reference

## Submit a job

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
  "webhook_url": "https://yourapp.com/webhooks/results",
  "execute_before": 1798761600000
}
```

`execute_before` is optional Unix time in milliseconds. EZThrottle checks it immediately before dispatch and before every retry. Work that has not started its next attempt by that time is never sent upstream; it becomes `failed` with reason `execution_deadline_exceeded`, remains pollable through the normal failed-result retention window, and emits the normal failed SSE/webhook event.

**Response headers your API can return to control pacing:**

| Header | Effect |
|---|---|
| `X-EZTHROTTLE-RPS: 10` | Raise or lower requests per second |
| `X-EZTHROTTLE-MAX-CONCURRENT: 5` | Change max in-flight requests |
| `X-EZTHROTTLE-ACCOUNT-QUEUE: enabled` | Switch to per-tenant queue isolation |
| `X-EZTHROTTLE-SLOW-START: true` | New queues ramp up instead of firing at full rate immediately |
| `X-EZTHROTTLE-MAX-BACKLOG: 10000` | Set the shared backlog budget used by fair admission |

With `X-EZTHROTTLE-SLOW-START: true` (or `X-Aqueduct-Slow-Start`), a new queue starts at a low floor rate and climbs toward its configured ceiling using the same gradual-recovery pacing that already brings a throttled queue back up, rather than firing at full speed on its very first dispatch. Applies per domain: a queue's first-ever dispatch has no prior response to read the signal from, so this takes effect on the *next* new queue created for that domain once any response has carried it — not the request that carried the header, and not retroactively for queues already running.

### Fair queue admission

Each upstream has a shared backlog budget `B`, defaulting to `EZTHROTTLE_MAX_PENDING_PER_UPSTREAM=10000`. The upstream may update it with `X-Aqueduct-Max-Backlog` (or `X-EZThrottle-Max-Backlog`); `0` disables this count-based limit. For a prospective request in AccountQueue mode, let `q` be its queue's projected backlog, `Q` the projected upstream backlog, and `N` the projected number of active account queues:

```text
F        = B / N
pressure = clamp((Q - 0.70B) / 0.30B, 0, 1)
excess   = clamp((q - F) / (B - F), 0, 1)
P(429)   = pressure * excess
```

A lone queue may use the whole budget. Below 70% pressure, idle capacity remains freely borrowable. Under congestion, above-share queues receive progressively more `429` responses while queues at or below `F` continue entering. If admission would put `Q` above `B`, it is rejected deterministically. Shared-queue mode uses `N=1`, so only the shared ceiling applies. Duplicate requests, recovered jobs, and internal webhook deliveries bypass fair admission; already-accepted work is never removed.

Accepted and fairness-rejected responses expose `X-Aqueduct-Active-Queues`, `X-Aqueduct-Upstream-Backlog`, `X-Aqueduct-Queue-Backlog`, and `X-Aqueduct-Admission-Pressure`, with `X-EZThrottle-*` aliases. Outbound dispatches include the active-queue and upstream-backlog values alongside the existing load headers. `GET /health` reports node-local totals under `queues`; Syn-connected siblings are used for an upstream's admission decision but are not mislabeled as local health state.

### Region-local queue ownership

EZThrottle Local uses libcluster for optional BEAM discovery and Syn for queue ownership. When `DNS_CLUSTER_QUERY` is set, connected nodes agree on one `AccountQueue` owner for each upstream and queue key; a request received by any node is routed to that owner before idempotency admission, persistence, and enqueueing. Pacing state and circuit-breaker changes are propagated between the upstream's URL actors. Without `DNS_CLUSTER_QUERY`, the same code path runs as a standalone one-node cluster.

This coordinates live processes; it does not turn each node's Mnesia directory into a replicated database. While the owning node is connected, job status and result calls route back to its local store. If that node is unavailable, its persisted jobs become available when it returns and performs normal recovery. Configure Mnesia replication separately if the deployment requires another node to serve that data during the owner's outage. Mnesia also binds its on-disk schema to the Erlang node name, so every clustered machine must retain the same node name when reusing its volume.

| Environment variable | Default | Effect |
|---|---:|---|
| `DNS_CLUSTER_QUERY` | unset | Enables libcluster DNS polling; all nodes must share their distribution cookie and node-name basename. Fly deployments remain stable singletons unless this is explicitly set |
| `EZTHROTTLE_CLUSTER_NODE_BASENAME` | release node basename | Overrides the basename libcluster uses for discovered node names |
| `EZTHROTTLE_CLUSTER_POLL_INTERVAL_MS` | `5000` | DNS discovery interval |
| `EZTHROTTLE_MAX_PENDING_PER_USER` | `10000` | Maximum queued plus in-flight jobs for one user in an account queue; `0` disables the ceiling |
| `EZTHROTTLE_MAX_PENDING_PER_UPSTREAM` | `10000` | Shared per-upstream backlog budget used by fair admission; `0` disables it |

The per-user ceiling rejects only new client work with `429` and `limit_reason: "user_queue"`; duplicates are still returned normally. Internal webhook deliveries and startup recovery bypass it so admission pressure cannot discard already-accepted work.

### Shared idempotency scope and request schemas

`"idempotency_scope": "shared"` (requires `EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED=true`, otherwise `400`) dedups on `idempotent_key` across every `user_id`, so concurrent callers coalesce onto one job. Followers receive `200 + "duplicate": true` with the existing `job_id`; on `/proxy` they are streamed that job.

With `EZTHROTTLE_L8_SCHEMA_VALIDATION=true`, a `url`-routed job whose upstream publishes L8 0.2 `request_schemas` for its method and path is validated before it is queued. A mismatch returns **422**:

```json
{
  "error": "request body does not match the schema the upstream advertises for POST /v1/chat/completions",
  "schema_route": "POST /v1/chat/completions",
  "schema_hash": "sha256:9c1e...",
  "schema_errors": "..."
}
```

Schemas are cached per upstream domain for up to 10 minutes and refetched when the upstream sends a new `X-Aqueduct-Schema-Hash`. Routes without a schema, upstreams without L8, and metadata that fails to fetch or compile are not checked.

## POST /proxy

Edge-gateway mode — see [Use cases](README.md#use-cases) for the deployment shape this is for. Same request body as `POST /jobs`, same idempotency/admission rules, but tries the upstream directly and synchronously first:

- **Succeeds directly** (2xx, or any status not classified as overload — see below): the real upstream's status, headers, and body are relayed back verbatim, on this same connection. The queue is never touched. A response the upstream didn't mark as overload (a plain `500`, a `404`, anything unclassified) is a **success** in this sense too — relayed directly, not queued, since nothing said it shouldn't be.
- **Fails, or the upstream signals overload** (timeout, a classified status code, or an ORCA fallback threshold): falls back to the exact same durable-queue-and-delivery path `POST /jobs` uses — the connection seamlessly becomes the same SSE stream `GET /jobs/:id/stream` provides, rather than requiring a second call. The very first event on that stream is `event: proxy_fallback`, `data: {"job_id", "reason", "upstream_status"}` (status omitted when no real response was received — a skipped attempt or a timeout) — so a client with no server of its own to explain this any other way (a browser, an agent) sees explicitly why it's in the queue before the normal `queued`/`dispatching`/terminal sequence starts. `reason` is one of `upstream_overloaded`, `upstream_unreachable`, `domain_degraded` (breaker open or this domain's queue already has backlog), or `pool_routed`.

**Which status codes count as overload is configurable, split into two kinds — queue locally, or also try cross-region redirect first (see below) — not lumped together the way "any 5xx" used to be.** Defaults are deliberately narrow: `429` → queue, `503` → reroute. Everything else (a plain `500`, `502`, `504`, `404`, anything not explicitly classified) is relayed to the caller as a normal, if unfortunate, direct response — not treated as overload at all. The reasoning: `429` is usually a *global* per-key/per-account rate limit, not a regional one — rerouting to a sibling region wouldn't help, since it hits the identical limit on the identical upstream, so it stays queue-only. `503` and an ORCA overload signal are reroute-eligible by default, since they more plausibly indicate *this* region/instance specifically is struggling.

Your own upstream can configure its own sets via response headers, comma-separated, each entry either a literal code or an HTTP status class (`5xx` matches every `500`–`599`):

| Header | Default | Effect |
|---|---|---|
| `X-Aqueduct-Queue-Codes` (or `X-EZThrottle-Queue-Codes`) | `429` | Statuses that mean "queue this domain locally" |
| `X-Aqueduct-Reroute-Codes` (or `X-EZThrottle-Reroute-Codes`) | `503` | Statuses that mean "also try cross-region redirect first" |

Due diligence is on you to say so if your upstream uses something nonstandard — e.g. `X-Aqueduct-Reroute-Codes: 502,503,504` to widen reroute eligibility, or `X-Aqueduct-Reroute-Codes: 5xx` to sweep in every 5xx the way earlier versions of this feature did unconditionally.

A domain that trips an overload signal has its direct attempts skipped entirely — anchored to the upstream's own `Retry-After` header when it sends one (× a configurable safety multiplier, default 3) as the minimum cooldown, but direct attempts stay skipped for as long as the domain's queue actually has real backlog, even past that cooldown — a fixed timer alone doesn't know whether the traffic it caused has finished draining. Once both the cooldown has elapsed *and* the queue is genuinely empty, the next request is itself a real probe against the live upstream. Which kind (queue vs. reroute) tripped the breaker is remembered for the whole cooldown — a domain breaker-tripped by a `429` stays queue-only on every retry during that window, not reroute-eligible just because *some* overload happened.

**Routine local backlog — no breaker tripped at all, just a queue with real jobs in it — never triggers redirect on its own**, even with the feature configured. A domain paced at a low rps under a normal traffic burst has jobs sitting in queue as a matter of course; that's this project working as designed, not a signal anything is regionally degraded. Redirect only ever gets tried alongside an actual tripped breaker or a failed/overloaded direct attempt.

The upstream can also proactively request queueing itself, on an otherwise-healthy response: `X-Aqueduct-Queue-Active: true` (or the product alias `X-EZTHROTTLE-QUEUE-ACTIVE`) trips the same breaker (always queue-kind, never reroute — matching its own name) for future requests to that domain — without discarding the response that already came back. Useful for "I'm nearing capacity, stop firing directly at me" ahead of an actual overload status.

Pool-routed jobs (`pool_id` instead of `url`) always fall straight to queue+stream — there's no single canonical upstream to try directly.

```bash
POST /proxy
Content-Type: application/json

{ ... same shape as POST /jobs ... }
```

### Cross-region redirect (Fly.io)

If `EZTHROTTLE_FLY_REGIONS` is set, an `upstream_unreachable` fallback, or an `upstream_overloaded`/`domain_degraded` fallback specifically classified as reroute-eligible (see `X-Aqueduct-Reroute-Codes` above — `503` by default, not every overload), tries other regions this app is deployed to — live, over Fly's private network — before falling back to this instance's own local queue. Off by default; unset, `/proxy` behaves exactly as described above with zero change. Direct port of Aquifer's own cross-region redirect (see [Aquifer's API.md](https://github.com/rjpruitt16/aquifer/blob/main/API.md#post-proxy)), kept in sync feature-for-feature.

When it triggers: every known-live region is tried for a fast direct success first, nearest (lowest measured round-trip time from the same health check that determines a region is live — Fly doesn't publish a region distance/latency table, so this doubles as the only real proximity signal available) first, except that two callers racing the same job always try one particular region first regardless of latency, so they tend to converge on the same region rather than each racing off after their own nearest option. If none can serve it directly, that same region is the one chosen to accept it into its own durable queue, and its live event stream is relayed back onto your original connection, so you see one continuous stream regardless of which region actually ends up handling the job.

A reroute is never silent to the caller — same principle as `proxy_fallback` above: a client with no server of its own to explain this shouldn't have to wonder why its connection is still open or where the response actually came from.
- **Direct success via redirect:** the response carries an `X-Aquifer-Served-By-Region` header naming which region actually served it, alongside the relayed status/headers/body.
- **Queued on another region:** before relaying that region's own stream, origin fires `event: rerouted`, `data: {"region"}` — arriving *before* that region's own `proxy_fallback`/`queued`/`dispatching` sequence, the same ordering `proxy_fallback` itself already uses relative to `queued`.

If literally no known-live region can help either — none live at all, or every one tried and failed — the request is **rejected**, not queued locally: **429**, `Retry-After` set to `EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS` (default 900 — a real regional outage, not a transient blip), `limit_reason: "redirect_exhausted"`, same response shape as an admission-control rejection. Queueing locally instead was never actually decided, so the default is to fail loudly rather than have the request land unnoticed on one struggling instance's queue. Separate from `EZTHROTTLE_REDIRECT_GATE_COOLDOWN_SECONDS` (default 500) — that one is purely internal probe-retry throttling, not what's told to the caller.

**Honest limitation, not silently glossed over:** this instance's idempotency check remains per-instance (Mnesia), unchanged by this feature. If the exact same `idempotent_key` is independently submitted to two different regions at nearly the same moment (a real scenario — a caller's own client retrying after a timeout can land on a different region via Fly's anycast), each region may independently begin its own redirect tour, and in rare cases the job could end up durably queued in two places. The deterministic region selection above narrows this window but does not close it. During cross-region redirect specifically, treat delivery as at-least-once, not exactly-once.

## GET /websocket

WebSocket proxying with an ordered Mnesia transcript, cursor replay, paced upstream connection admission, and automatic reconnect. This is the same `aqueduct.v1` wire contract Aquifer exposes. EZThrottle Local does **not** authenticate callers or choose their destination; put it behind a trusted gateway that authenticates the request and injects the upstream URL.

WebSockets are enabled by default because Mnesia is already part of EZThrottle Local. `EZTHROTTLE_WS_ENABLED=false` is an operational kill switch.

### Handshake

```http
GET /websocket?session_id=session-123&after=0-0 HTTP/1.1
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Protocol: aqueduct.v1
Authorization: Bearer gateway-authenticated-identity
X-Aqueduct-Upstream-URL: wss://backend.internal/socket
```

`session_id` identifies the durable transcript. `after` is the last stream ID the client processed and defaults to `0-0`. EZThrottle replays backend messages after that cursor before following live events. A cursor older than retained history returns **409** instead of silently skipping data.

The trusted upstream URL must be absolute `ws://` or `wss://`. When `EZTHROTTLE_ALLOWED_URL_DOMAINS` is set, its comma-separated hosts are enforced as an allowlist. Gateway headers such as `Authorization` are forwarded; hop-by-hop and internal Aqueduct/Aquifer headers are stripped, and `X-Aqueduct-Session-ID` is injected upstream.

### Messages

Every application message is a JSON `aqueduct.v1` envelope. Raw frames are not supported.

```json
{"type":"command","message_id":"command-42","payload":{"action":"start"}}
```

The client must keep `message_id` stable across retries. EZThrottle persists the command before forwarding it and confirms that write:

```json
{"type":"command_recorded","message_id":"command-42","stream_id":"1798053731000-1"}
```

Backend acknowledgements and events use the same shapes as Aquifer:

```json
{"type":"ack","message_id":"ack-42","caused_by":"command-42"}
{"type":"event","message_id":"event-43","caused_by":"command-42","payload":{"state":"running"}}
```

Every backend `ack` or `event` is persisted before client delivery. `caused_by` permits one command to produce zero, one, or many events. Delivery after cursor reconnect is at least once. After an ambiguous upstream disconnect, persisted commands are not automatically replayed because EZThrottle cannot know whether the backend acted before the socket disappeared; backend actions must be idempotent by `message_id`.

Live, non-durable status envelopes report `replaying`, `replay_complete`, `waiting`, `connecting`, `connected`, and `reconnecting`. Waiting messages include the current FIFO `position`; reconnecting messages include `retry_after_ms`.

### Capacity and retention

Connection ceilings and slow start are local to one EZThrottle process. A backend can lower this process's ceiling or opening rate through successful-handshake headers:

```http
X-Aqueduct-WS-Max-Connections: 250
X-Aqueduct-WS-Connect-Rps: 20
```

It may update either limit on an established connection using `{"type":"aqueduct.capacity","max_connections":250,"connect_rps":20}`. Dynamic signals can only lower operator ceilings. Successful handshakes double the slow-start ramp toward its configured maximum; a failed handshake resets it. Opening and reconnect delays include jitter.

Transcripts retain the newest configured events and expire after an idle TTL. Mnesia uses the same `EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS` durability tradeoff as job storage. The current schema is local to one node, so cross-node replay requires sticky routing or a separately configured replicated Mnesia topology.

| Environment variable | Default |
|---|---:|
| `EZTHROTTLE_WS_ENABLED` | `true` |
| `EZTHROTTLE_WS_STREAM_MAX_EVENTS` | `10000` |
| `EZTHROTTLE_WS_STREAM_TTL_SECONDS` | `86400` |
| `EZTHROTTLE_WS_READ_BATCH` | `100` |
| `EZTHROTTLE_WS_MAX_MESSAGE_BYTES` | `1048576` |
| `EZTHROTTLE_WS_HANDSHAKE_TIMEOUT_SECONDS` | `10` |
| `EZTHROTTLE_WS_RECONNECT_MAX_SECONDS` | `30` |
| `EZTHROTTLE_WS_IDLE_TIMEOUT_SECONDS` | `30` |
| `EZTHROTTLE_WS_MAX_CLIENT_CONNECTIONS` | `1000` |
| `EZTHROTTLE_WS_MAX_UPSTREAM_CONNECTIONS` | `1000` |
| `EZTHROTTLE_WS_MAX_WAITING_CONNECTIONS` | `1000` |
| `EZTHROTTLE_WS_CONNECT_RPS` | `20` |
| `EZTHROTTLE_WS_SLOW_START_RPS` | `1` |

Handshake errors match Aquifer: **400** for invalid protocol/session/upstream input, **409** for a replay gap, and **429** for the local client ceiling. `GET /health` exposes the local client, waiting, active-upstream, configured, ramp, and effective limits under `websocket`.

## Stream job events (SSE)

```bash
GET /jobs/:id/stream
```

Opens a server-sent event stream. Events: `queued`, `position`, `dispatching`, `completed`, `failed`. Keepalive pings sent every 30 seconds. If you disconnect before completion, the result is delivered to your `webhook_url`.

## Check job status

```bash
GET /jobs/:id
```

Queued or in-flight jobs return status and request metadata. Completed or failed jobs also include a
durable `result` object with the same terminal payload delivered over SSE/webhook:

```json
{
  "job_id": "abc123",
  "status": "completed",
  "url": "https://api.yourservice.com/process",
  "method": "POST",
  "created_at": 1798053642000,
  "result": {
    "job_id": "abc123",
    "status": "completed",
    "response_status": 200,
    "body": "{\"ok\":true}"
  }
}
```

Terminal duplicate submissions return the same stored result inline with `duplicate: true`.

## Health check

```bash
GET /health
```
