# Test validation — missing required fields return 400

# Missing user_id
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "idempotent_key": "val-test-001",
  "url": "https://httpbin.org/get",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 400
[Asserts]
jsonpath "$.error" exists

# Missing url
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "idempotent_key": "val-test-002",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 400
[Asserts]
jsonpath "$.error" exists

# Missing idempotent_key
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "url": "https://httpbin.org/get",
  "method": "GET",
  "webhook_url": "{{WEBHOOK_CALLBACK_URL}}"
}
HTTP 400
[Asserts]
jsonpath "$.error" exists

# Missing webhook_url
POST {{EZTHROTTLE_URL}}/jobs
Content-Type: application/json
{
  "user_id": "user_001",
  "idempotent_key": "val-test-003",
  "url": "https://httpbin.org/get",
  "method": "GET"
}
HTTP 400
[Asserts]
jsonpath "$.error" exists

# Unknown job id returns 404
GET {{EZTHROTTLE_URL}}/jobs/doesnotexist000000000000000000000
HTTP 404
[Asserts]
jsonpath "$.error" exists
