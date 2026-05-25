#!/usr/bin/env python3
"""
SSE streaming integration tests for ezthrottle-local.

Three cases:
  1. Happy path  — stream receives queued → position → dispatching → completed in order
  2. Disconnect  — client disconnects mid-job, webhook fires with the result
  3. Position    — multiple jobs under same queue key, position counts down correctly
"""

import json
import os
import requests
import sys
import threading
import time
import uuid

EZTHROTTLE_URL = os.getenv("EZTHROTTLE_URL", "http://localhost:4000")
WEBHOOK_URL    = os.getenv("WEBHOOK_URL", "http://localhost:9090")
WEBHOOK_CB     = os.getenv("WEBHOOK_CALLBACK_URL", "http://localhost:9090/webhook")
TARGET_URL     = os.getenv("TARGET_URL", "https://httpbin.org/get")

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"

failures = []


def fail(test, reason):
    print(f"  {FAIL} {test}: {reason}")
    failures.append((test, reason))


def ok(test):
    print(f"  {PASS} {test}")


def submit_job(user_id="test-user", extra_headers=None):
    payload = {
        "user_id": user_id,
        "idempotent_key": str(uuid.uuid4()),
        "url": TARGET_URL,
        "method": "GET",
        "headers": extra_headers or {},
        "webhook_url": WEBHOOK_CB,
    }
    r = requests.post(f"{EZTHROTTLE_URL}/jobs", json=payload, timeout=5)
    r.raise_for_status()
    return r.json()["job_id"]


def collect_sse_events(job_id, stop_after=None, disconnect_after_event=None, timeout=30):
    """
    Opens the SSE stream for job_id and collects events.
    stop_after: stop once this event type is seen
    disconnect_after_event: disconnect immediately after seeing this event type
    Returns list of event dicts.
    """
    events = []
    url = f"{EZTHROTTLE_URL}/jobs/{job_id}/stream"

    try:
        with requests.get(url, stream=True, timeout=timeout) as resp:
            resp.raise_for_status()
            event_type = None
            for line in resp.iter_lines(decode_unicode=True):
                if line.startswith("event:"):
                    event_type = line.split(":", 1)[1].strip()
                elif line.startswith("data:") and event_type:
                    data = json.loads(line.split(":", 1)[1].strip())
                    events.append({"event": event_type, "data": data})

                    if disconnect_after_event and event_type == disconnect_after_event:
                        return events  # close connection abruptly

                    if stop_after and event_type == stop_after:
                        return events

                    event_type = None
    except Exception as e:
        if not events:
            raise
    return events


def wait_for_webhook(job_id, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = requests.get(f"{WEBHOOK_URL}/webhooks/{job_id}", timeout=5)
        if r.status_code == 200 and r.json().get("webhook"):
            return r.json()["webhook"]["json"]
        time.sleep(0.5)
    return None


# ---- Reset ----------------------------------------------------------------

def reset():
    requests.post(f"{WEBHOOK_URL}/reset", timeout=5)


# ---- Test 1: Happy path stream -------------------------------------------

def test_happy_path():
    print("\nTest 1: Happy path stream")
    reset()
    job_id = submit_job()

    events = collect_sse_events(job_id, stop_after="completed", timeout=30)
    event_names = [e["event"] for e in events]

    if "queued" not in event_names:
        fail("queued event received", f"got {event_names}")
    else:
        ok("queued event received")

    if "dispatching" not in event_names:
        fail("dispatching event received", f"got {event_names}")
    else:
        ok("dispatching event received")

    if "completed" not in event_names:
        fail("completed event received", f"got {event_names}")
    else:
        ok("completed event received")

    completed = next((e for e in events if e["event"] == "completed"), None)
    if completed and completed["data"].get("response_status"):
        ok("completed carries response_status")
    else:
        fail("completed carries response_status", f"data={completed}")

    queued_idx      = next((i for i, e in enumerate(events) if e["event"] == "queued"), None)
    dispatching_idx = next((i for i, e in enumerate(events) if e["event"] == "dispatching"), None)
    completed_idx   = next((i for i, e in enumerate(events) if e["event"] == "completed"), None)

    if None not in (queued_idx, dispatching_idx, completed_idx) and \
       queued_idx < dispatching_idx < completed_idx:
        ok("events arrive in order: queued → dispatching → completed")
    else:
        fail("events arrive in order", f"indices: queued={queued_idx} dispatching={dispatching_idx} completed={completed_idx}")


# ---- Test 2: Disconnect fallback -----------------------------------------

def test_disconnect_fallback():
    print("\nTest 2: Disconnect fallback — webhook fires after stream drops")
    reset()
    job_id = submit_job()

    # Disconnect as soon as we see the queued event — job is still in flight
    events = collect_sse_events(job_id, disconnect_after_event="queued", timeout=15)

    if not any(e["event"] == "queued" for e in events):
        fail("connected and received queued event before disconnect", f"got {[e['event'] for e in events]}")
        return
    ok("connected and received queued event before disconnect")

    # Webhook must still deliver the result
    webhook = wait_for_webhook(job_id, timeout=30)
    if webhook is None:
        fail("webhook delivered after stream disconnect", "no webhook received within 30s")
    elif webhook.get("status") == "completed":
        ok("webhook delivered after stream disconnect")
    else:
        fail("webhook delivered after stream disconnect", f"webhook payload={webhook}")


# ---- Test 3: Position counts down ----------------------------------------

def test_position_updates():
    print("\nTest 3: Position updates count down as queue drains")
    reset()

    # Submit 3 jobs under the same user+api_key so they share a queue.
    # Use a shared api_key header to force them into the same AccountQueue.
    shared_headers = {"x-api-key": "test-key-position"}
    job_ids = [submit_job(user_id="position-user", extra_headers=shared_headers) for _ in range(3)]

    # Watch the last job — it starts at position 3 and should count down
    last_job_id = job_ids[-1]
    events = collect_sse_events(last_job_id, stop_after="completed", timeout=60)

    position_events = [e for e in events if e["event"] == "position"]
    positions = [e["data"].get("position") for e in position_events]

    if not positions:
        fail("position events received", "no position events seen")
        return
    ok(f"position events received: {positions}")

    if positions[0] > 1:
        ok(f"initial position is > 1 (got {positions[0]})")
    else:
        fail("initial position is > 1", f"got {positions[0]} — jobs may not have shared a queue")

    if positions == sorted(positions, reverse=True) or positions[-1] <= positions[0]:
        ok("position counts down over time")
    else:
        fail("position counts down over time", f"positions={positions}")


# ---- Main ----------------------------------------------------------------

if __name__ == "__main__":
    print(f"SSE streaming tests against {EZTHROTTLE_URL}")
    print(f"Webhook server at {WEBHOOK_URL}")

    test_happy_path()
    test_disconnect_fallback()
    test_position_updates()

    print()
    if failures:
        print(f"{FAIL} {len(failures)} test(s) failed:")
        for name, reason in failures:
            print(f"  - {name}: {reason}")
        sys.exit(1)
    else:
        print(f"{PASS} All streaming tests passed!")
        sys.exit(0)
