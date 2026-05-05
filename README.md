# EZThrottle Local

A self-hosted, open-source API rate limit router built on the BEAM.

Kubernetes and modern orchestrators are great at scaling compute — but they were not designed for spiky traffic or tenant fairness. When a burst of agentic requests arrives, your pods get hammered, queues back up unevenly, and noisy tenants crowd out everyone else. Horizontal scaling helps eventually, but the spike hits before a new pod is ready.

**EZThrottle Local is a singleton, in-memory, webhook-driven load balancer for outbound API traffic.** When spiky agentic traffic arrives, it is queued in memory and forwarded to your microservices or external APIs at a controlled, predictable pace. As Kubernetes scales your upstream capacity, you respond with a higher RPS header and EZThrottle adjusts in real time — no redeploy needed.

## How it works

```
Client → POST /jobs → EZThrottle Local → paced outbound requests → Your API
                                      ↓
                               webhook delivery
                                      ↓
                                  Your App
```

1. **Submit a job** — POST the request you want forwarded, with a `webhook_url` for the response.
2. **EZThrottle queues it** — Jobs are held in memory and dispatched at the configured RPS.
3. **Your API responds** — EZThrottle reads `X-EZTHROTTLE-RPS` and `X-EZTHROTTLE-MAX-CONCURRENT` headers from the response and adjusts pace automatically.
4. **Webhook delivery** — The response body and status are POSTed to your `webhook_url`.

## Per-tenant fairness (AccountQueue mode)

By default all traffic for a destination flows through one shared queue. When your API responds with:

```
X-EZTHROTTLE-ACCOUNT-QUEUE: enabled
```

EZThrottle switches to per-user isolation — each `user_id` + API key gets its own queue. A heavy user no longer blocks everyone else. Different tenants naturally get different paces based on what your service signals back. Disable it any time by responding with `X-EZTHROTTLE-ACCOUNT-QUEUE: disabled`.

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

### Check job status

```bash
GET /jobs/:id
```

### Health check

```bash
GET /health
```

## Idempotency

Every job requires an `idempotent_key`. Submitting the same key twice returns the original job ID without re-executing the request. Keys expire after 24 hours (configurable).

## Configuration

```elixir
# config/runtime.exs
config :ezthrottle_local,
  default_rps: 2.0,
  account_queue_enabled: false,   # opt-in per-tenant isolation
  idempotent_ttl: 86_400          # seconds
```

## Running locally

```bash
mix setup
mix phx.server
```

Integration tests (requires `hurl` and Python 3 with Flask):

```bash
make integration-test
```

## Docker

```bash
docker build -t ezthrottle-local .
docker run -p 4000:4000 ezthrottle-local
```

## Deploy to Fly.io

```bash
fly launch --config fly.toml
fly deploy
```

## EZThrottle Cloud

EZThrottle Local is best-effort: in-memory queues, single node, no retry on failure.

**[EZThrottle Cloud](https://ezthrottle.network)** handles the cases this cannot:

- **Multi-step workflows** — chain dependent API calls with conditional branching
- **Partial outage recovery** — jobs survive pod restarts and region failures
- **Guaranteed delivery** — automatic retry with backoff and dead-letter queues
- **Internal + external traffic** — protect both your own services and third-party APIs from the same control plane
- **Distributed fairness** — per-tenant rate limiting across multiple nodes and regions

EZThrottle Local is the right tool for teams that want to get started immediately with zero infrastructure. When you need durability and cross-region guarantees, EZThrottle Cloud picks up where this leaves off.
