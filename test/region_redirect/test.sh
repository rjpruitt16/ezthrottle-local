#!/usr/bin/env bash
# Drives the real redirect scenario against the deployment from deploy.sh,
# entirely via `fly proxy` tunnels (never a public URL), and asserts on
# both the HTTP response and origin's own [redirect] log lines. Direct
# adaptation of aquifer/tests/region-redirect/test.sh.
#
# Scenario: origin's region has genuine backlog on a domain (from a real
# POST /jobs submission against a temporarily-failing upstream), the other
# region doesn't -- so a real POST /proxy request on origin should
# redirect and come back served directly by the other region.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/lib.sh"
require_state

SUFFIX="$(date +%s)-$RANDOM"

trap proxies_down EXIT
echo "== Opening fly proxy tunnels to $APP_NAME ($ORIGIN_MACHINE_ID) and $RECORDER_APP =="
proxies_up

RECORDER_INTERNAL_URL="http://$RECORDER_APP.internal:5000"

echo ""
echo "== Scenario: origin's region has real backlog on a domain, target region doesn't =="

curl -sf -X POST "http://localhost:$RECORDER_PROXY_PORT/reset" > /dev/null

echo "-- Step 1: configure the shared upstream to fail, submit a real POST /jobs request to origin (creates real backlog for this domain on origin specifically)"
curl -sf -X POST "http://localhost:$RECORDER_PROXY_PORT/upstream/configure" \
  -H "Content-Type: application/json" \
  -d '{"status": 503, "body": "still down"}' > /dev/null

BACKLOG_JOB_ID="$(curl -sf -X POST "http://localhost:$APP_PROXY_PORT/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"redirect-e2e\",\"idempotent_key\":\"backlog-$SUFFIX\",\"url\":\"$RECORDER_INTERNAL_URL/upstream/target\",\"method\":\"POST\",\"webhook_url\":\"$RECORDER_INTERNAL_URL/webhook\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')"
echo "   queued backlog job: $BACKLOG_JOB_ID"

echo "-- Step 2: reconfigure the upstream to succeed (target region can now serve it directly; origin still has real backlog from step 1)"
curl -sf -X POST "http://localhost:$RECORDER_PROXY_PORT/upstream/configure" \
  -H "Content-Type: application/json" \
  -d '{"status": 200, "body": "{\"ok\": true}", "headers": {"X-Served-By-Test": "recorder"}}' > /dev/null

# Baseline before issuing the actual test request -- fly logs' propagation
# lag/window means the log-assertion step below needs to look for lines
# that are NEW relative to this baseline, not just present at all, or a
# stale entry from a PRIOR run (e.g. the backlog job above, or an earlier
# invocation of this script) can produce a false pass.
LOGS_BEFORE="$(fly logs --app "$APP_NAME" --no-tail 2>&1 | grep '\[redirect\]' || true)"

echo "-- Step 3: the real test request, via POST /proxy on origin"
RESP_HEADERS="$(mktemp)"
RESP_BODY="$(curl -sf -D "$RESP_HEADERS" -X POST "http://localhost:$APP_PROXY_PORT/proxy" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"redirect-e2e\",\"idempotent_key\":\"redirect-test-$SUFFIX\",\"url\":\"$RECORDER_INTERNAL_URL/upstream/target\",\"method\":\"POST\",\"webhook_url\":\"$RECORDER_INTERNAL_URL/webhook\"}")"

echo "   response headers:"
cat "$RESP_HEADERS"
echo "   response body: $RESP_BODY"

# Redirect can legitimately resolve either of two ways -- both are a real
# pass, not just one: target dispatched directly (fast path), or target
# accepted it into its own durable queue and streamed the full lifecycle
# live (e.g. under real cross-region latency to a third region, target's
# own direct-attempt timeout can legitimately trip -- that's genuine
# behavior against real infrastructure, not a bug). Accept whichever
# actually happened.
FAIL=0
if grep -qi "^content-type: text/event-stream" "$RESP_HEADERS"; then
  echo "   (queue-commit path: target queued it and streamed the result live)"
  if ! echo "$RESP_BODY" | grep -q "event: rerouted"; then
    echo "FAIL: expected a rerouted event announcing which region the job landed on" >&2
    FAIL=1
  fi
  if ! echo "$RESP_BODY" | grep -q '"region":"ord"'; then
    echo "FAIL: expected the rerouted event to name ord as the region" >&2
    FAIL=1
  fi
  if ! echo "$RESP_BODY" | grep -q "event: completed"; then
    echo "FAIL: expected the relayed stream to reach a real completed event" >&2
    FAIL=1
  fi
else
  echo "   (direct-success path: target dispatched it directly)"
  if ! grep -qi "^x-served-by-test: recorder" "$RESP_HEADERS"; then
    echo "FAIL: expected the recorder's response header relayed verbatim (direct success via redirect)" >&2
    FAIL=1
  fi
  if ! grep -qi "^x-aquifer-served-by-region:" "$RESP_HEADERS"; then
    echo "FAIL: expected x-aquifer-served-by-region on a direct-success-via-redirect response" >&2
    FAIL=1
  fi
fi
rm -f "$RESP_HEADERS"

echo ""
echo "== Confirming via origin's own logs that redirect actually triggered =="
NEW_LOGS=""
for i in $(seq 1 10); do
  CURRENT_LOGS="$(fly logs --app "$APP_NAME" --no-tail 2>&1 | grep '\[redirect\]' || true)"
  NEW_LOGS="$(comm -13 <(echo "$LOGS_BEFORE" | sort) <(echo "$CURRENT_LOGS" | sort))"
  if echo "$NEW_LOGS" | grep -q "trying candidates" && echo "$NEW_LOGS" | grep -q "succeeded directly\|accepted it into its own queue"; then
    break
  fi
  sleep 3
done
echo "$NEW_LOGS"
if ! echo "$NEW_LOGS" | grep -q "trying candidates"; then
  echo "FAIL: expected origin's logs to show a real redirect attempt was made" >&2
  FAIL=1
fi
if ! echo "$NEW_LOGS" | grep -q "succeeded directly\|accepted it into its own queue"; then
  echo "FAIL: expected origin's logs to show the redirect actually resolved somewhere" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "== FAIL: cross-region redirect test did not pass =="
  exit 1
fi

echo ""
echo "== PASS: cross-region redirect confirmed against real Fly infrastructure =="
