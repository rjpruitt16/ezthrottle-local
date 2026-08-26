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
