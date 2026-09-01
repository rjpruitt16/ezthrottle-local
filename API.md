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
  "webhook_url": "https://yourapp.com/webhooks/results"
}
```

**Response headers your API can return to control pacing:**

| Header | Effect |
|---|---|
| `X-EZTHROTTLE-RPS: 10` | Raise or lower requests per second |
| `X-EZTHROTTLE-MAX-CONCURRENT: 5` | Change max in-flight requests |
| `X-EZTHROTTLE-ACCOUNT-QUEUE: enabled` | Switch to per-tenant queue isolation |

## POST /proxy

Edge-gateway mode — see [Use cases](README.md#use-cases) for the deployment shape this is for. Same request body as `POST /jobs`, same idempotency/admission rules, but tries the upstream directly and synchronously first:

- **Succeeds directly** (2xx, no overload signal): the real upstream's status, headers, and body are relayed back verbatim, on this same connection. The queue is never touched.
- **Fails or the upstream signals overload** (timeout, 5xx, `429`, or an ORCA fallback threshold): falls back to the exact same durable-queue-and-delivery path `POST /jobs` uses — the connection seamlessly becomes the same SSE stream `GET /jobs/:id/stream` provides, rather than requiring a second call. The very first event on that stream is `event: proxy_fallback`, `data: {"job_id", "reason", "upstream_status"}` (status omitted when no real response was received — a skipped attempt or a timeout) — so a client with no server of its own to explain this any other way (a browser, an agent) sees explicitly why it's in the queue before the normal `queued`/`dispatching`/terminal sequence starts. `reason` is one of `upstream_overloaded`, `upstream_unreachable`, `domain_degraded` (breaker open or this domain's queue already has backlog), or `pool_routed`.

A domain that trips an overload signal has its direct attempts skipped entirely — anchored to the upstream's own `Retry-After` header when it sends one (× a configurable safety multiplier, default 3) as the minimum cooldown, but direct attempts stay skipped for as long as the domain's queue actually has real backlog, even past that cooldown — a fixed timer alone doesn't know whether the traffic it caused has finished draining. Once both the cooldown has elapsed *and* the queue is genuinely empty, the next request is itself a real probe against the live upstream.

The upstream can also proactively request this itself, on an otherwise-healthy response: `X-Aqueduct-Queue-Active: true` (or the product alias `X-EZTHROTTLE-QUEUE-ACTIVE`) trips the same breaker for future requests to that domain — without discarding the response that already came back. Useful for "I'm nearing capacity, stop firing directly at me" ahead of an actual `429`/`5xx`.

Pool-routed jobs (`pool_id` instead of `url`) always fall straight to queue+stream — there's no single canonical upstream to try directly.

```bash
POST /proxy
Content-Type: application/json

{ ... same shape as POST /jobs ... }
```

### Cross-region redirect (Fly.io)

If `EZTHROTTLE_FLY_REGIONS` is set, a `domain_degraded`/`upstream_unreachable`/`upstream_overloaded` fallback tries other regions this app is deployed to — live, over Fly's private network — before falling back to this instance's own local queue. Off by default; unset, `/proxy` behaves exactly as described above with zero change. Direct port of Aquifer's own cross-region redirect (see [Aquifer's API.md](https://github.com/rjpruitt16/aquifer/blob/main/API.md#post-proxy)), kept in sync feature-for-feature.

When it triggers: every known-live region is tried for a fast direct success first, nearest (lowest measured round-trip time from the same health check that determines a region is live — Fly doesn't publish a region distance/latency table, so this doubles as the only real proximity signal available) first, except that two callers racing the same job always try one particular region first regardless of latency, so they tend to converge on the same region rather than each racing off after their own nearest option. If none can serve it directly, that same region is the one chosen to accept it into its own durable queue, and its live event stream is relayed back onto your original connection, so you see one continuous stream regardless of which region actually ends up handling the job.

A reroute is never silent to the caller — same principle as `proxy_fallback` above: a client with no server of its own to explain this shouldn't have to wonder why its connection is still open or where the response actually came from.
- **Direct success via redirect:** the response carries an `X-Aquifer-Served-By-Region` header naming which region actually served it, alongside the relayed status/headers/body.
- **Queued on another region:** before relaying that region's own stream, origin fires `event: rerouted`, `data: {"region"}` — arriving *before* that region's own `proxy_fallback`/`queued`/`dispatching` sequence, the same ordering `proxy_fallback` itself already uses relative to `queued`.

If literally no known-live region can help either — none live at all, or every one tried and failed — the request is **rejected**, not queued locally: **429**, `Retry-After` set to `EZTHROTTLE_REDIRECT_EXHAUSTED_RETRY_AFTER_SECONDS` (default 900 — a real regional outage, not a transient blip), `limit_reason: "redirect_exhausted"`, same response shape as an admission-control rejection. Queueing locally instead was never actually decided, so the default is to fail loudly rather than have the request land unnoticed on one struggling instance's queue. Separate from `EZTHROTTLE_REDIRECT_GATE_COOLDOWN_SECONDS` (default 500) — that one is purely internal probe-retry throttling, not what's told to the caller.

**Honest limitation, not silently glossed over:** this instance's idempotency check remains per-instance (Mnesia), unchanged by this feature. If the exact same `idempotent_key` is independently submitted to two different regions at nearly the same moment (a real scenario — a caller's own client retrying after a timeout can land on a different region via Fly's anycast), each region may independently begin its own redirect tour, and in rare cases the job could end up durably queued in two places. The deterministic region selection above narrows this window but does not close it. During cross-region redirect specifically, treat delivery as at-least-once, not exactly-once.

## Stream job events (SSE)

```bash
GET /jobs/:id/stream
```

Opens a server-sent event stream. Events: `queued`, `position`, `dispatching`, `completed`, `failed`. Keepalive pings sent every 30 seconds. If you disconnect before completion, the result is delivered to your `webhook_url`.

## Check job status

```bash
GET /jobs/:id
```

## Health check

```bash
GET /health
```
