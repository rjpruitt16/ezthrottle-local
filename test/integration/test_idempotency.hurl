# Test idempotency — same idempotent_key returns existing job, not a new one

# Reset
POST {{WEBHOOK_URL}}/reset
HTTP 200

# Submit first job
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "idempotent_key": "idem-test-{{timestamp}}",
  "url": "https://httpbin.org/get",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 201
[Asserts]
jsonpath "$.job_id" exists
jsonpath "$.status" == "queued"
[Captures]
first_job_id: jsonpath "$.job_id"

# Submit exact same idempotent_key again — should return duplicate
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "idempotent_key": "idem-test-{{timestamp}}",
  "url": "https://httpbin.org/get",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 200
[Asserts]
jsonpath "$.job_id" == "{{first_job_id}}"
jsonpath "$.duplicate" == true

# Wait for the first job's webhook to arrive
GET {{WEBHOOK_URL}}/webhooks/{{first_job_id}}
[Options]
retry: 20
retry-interval: 1000
HTTP 200
[Asserts]
jsonpath "$.webhook.json.job_id" == "{{first_job_id}}"
jsonpath "$.webhook.json.status" == "completed"

# Verify the duplicate did not trigger a second webhook (only 1 for this job)
GET {{WEBHOOK_URL}}/webhooks/{{first_job_id}}
HTTP 200
[Asserts]
jsonpath "$.count" == 1
