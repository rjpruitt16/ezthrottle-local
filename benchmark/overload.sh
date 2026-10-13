#!/usr/bin/env bash
# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

# Overload: drive Spillway well past what it can handle and check that it
# degrades safely instead of falling over. Soak runs 2 and 3 found three
# ways it fell over (memory growing with retention, cleanup falling behind,
# store writes queuing), each of them something growing without bound. A
# pass means:
#
#   no loss    every accepted job's webhook arrives (loadgen's backlog after
#              its 60s drain is 0)
#   sheds      the excess is refused with 429s, not queued
#   bounded    memory in the second half of the load grows less than 15%
#              over the first half, and stays under SPILLWAY_MEMORY_LIMIT_MB
#   recovers   60s after the load stops, the store backlog is back to 0
#
# Uses Aquifer's benchmark/loadgen, which also serves the upstream and the
# webhook receiver (port 8080 on this machine; SELF is how the target
# reaches it). Run it on a machine like the one you deploy to; on a laptop,
# pin the BEAM to one scheduler (ELIXIR_ERL_OPTIONS="+S 1:1").
#
#   LOADGEN=/path/to/loadgen benchmark/overload.sh http://127.0.0.1:4000 http://127.0.0.1:8080 1000 300
set -euo pipefail

TARGET="${1:-http://127.0.0.1:4000}"
SELF="${2:-http://127.0.0.1:8080}"
RATE="${3:-1000}"
SECONDS_UNDER_LOAD="${4:-300}"
LOADGEN="${LOADGEN:-loadgen}"
OUT="$(mktemp -d)"

health() {
  curl -sf --max-time 5 "$TARGET/health" | python3 -c '
import json, sys, time
a = json.load(sys.stdin)["admission"]
print(json.dumps({"t": time.time(), "memory_mb": a.get("memory_mb"),
                  "limit_mb": a.get("memory_limit_mb"),
                  "backlog": a.get("store_backlog"),
                  "processes": a.get("processes")}))' || true
}

( while :; do health >> "$OUT/health.jsonl"; sleep 5; done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

echo "Overloading $TARGET at $RATE jobs/s for ${SECONDS_UNDER_LOAD}s"
START=$(date +%s)
"$LOADGEN" -target "$TARGET" -self "$SELF" -rates "$RATE" -step "${SECONDS_UNDER_LOAD}s" | tee "$OUT/load.txt"
# loadgen waits up to 60s for webhooks after the load; give the store the
# same again to settle, then take the last reading.
sleep 60
kill $SAMPLER 2>/dev/null || true
health >> "$OUT/health.jsonl"

python3 - "$OUT" "$START" "$SECONDS_UNDER_LOAD" <<'EOF'
import json, re, sys

out, start, duration = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
load = open(f"{out}/load.txt").read()
samples = [json.loads(l) for l in open(f"{out}/health.jsonl") if l.strip()]

row = re.search(r"^\s*\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", load, re.M)
accepted, shed = (int(row.group(1)), int(row.group(3))) if row else (0, 0)
drain = re.search(r"backlog after \d+s drain wait: (-?\d+)", load)
hits = re.search(r"upstream hits (\d+), webhooks (\d+)", load)
# loadgen prints its drain line only when the target couldn't keep up;
# otherwise every dispatched job should have its webhook.
if drain:
    left = int(drain.group(1))
elif hits:
    left = int(hits.group(1)) - int(hits.group(2))
else:
    left = None

during = [s for s in samples if start <= s["t"] <= start + duration]
half = len(during) // 2
first = max((s["memory_mb"] for s in during[:half]), default=0)
second = max((s["memory_mb"] for s in during[half:]), default=0)
limit = next((s["limit_mb"] for s in samples if s.get("limit_mb")), 0)
final = samples[-1] if samples else {}

checks = [
    ("no loss", left == 0, f"webhooks still missing after drain: {left}"),
    ("sheds", shed > 0, f"{accepted}/s accepted, {shed}/s refused with 429"),
    ("bounded", first > 0 and second <= first * 1.15 and (not limit or second < limit),
     f"memory max {first} MB first half, {second} MB second half, limit {limit or 'unset'}"),
    ("recovers", final.get("backlog") == 0,
     f"store backlog after the load: {final.get('backlog')}, processes {final.get('processes')}"),
]
if shed == 0:
    print("note: the target kept up with this rate, so it wasn't overloaded; raise RATE")
failed = False
for name, ok, detail in checks:
    print(f"{'PASS' if ok else 'FAIL'}  {name:9} {detail}")
    failed |= not ok
print(f"samples: {out}/health.jsonl")
sys.exit(1 if failed else 0)
EOF
