# Test 1: Health check
GET {{EZTHROTTLE_URL}}/health
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

# Test 2: Reset webhook server
POST {{WEBHOOK_URL}}/reset
HTTP 200
[Asserts]
jsonpath "$.status" == "reset"

# Test 3: Submit a job
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "idempotent_key": "smoke-test-{{timestamp}}",
  "url": "https://httpbin.org/get",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 201
[Asserts]
jsonpath "$.job_id" exists
jsonpath "$.status" == "queued"
[Captures]
job_id: jsonpath "$.job_id"

# Test 4: Poll job status — should be queued or completed
GET {{EZTHROTTLE_URL}}/jobs/{{job_id}}
HTTP 200
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"
jsonpath "$.status" exists

# Test 5: Wait for webhook delivery
GET {{WEBHOOK_URL}}/webhooks
[Options]
retry: 20
retry-interval: 1000
HTTP 200
[Asserts]
jsonpath "$.count" >= 1

# Test 6: Confirm webhook payload
GET {{WEBHOOK_URL}}/webhooks/{{job_id}}
HTTP 200
[Asserts]
jsonpath "$.webhook.json.job_id" == "{{job_id}}"
jsonpath "$.webhook.json.status" == "completed"
jsonpath "$.webhook.json.response_status" exists
