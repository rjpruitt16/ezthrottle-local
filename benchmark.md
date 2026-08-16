# Benchmarks

Real runs against a live deployment (`ezthrottle-local.fly.dev`), same `shared-cpu-1x`/512MB Fly.io tier and methodology as [Aquifer's benchmark.md](https://github.com/rjpruitt16/aquifer/blob/main/benchmark.md), the Go/SQLite sibling this project mirrors. Scripts are in [`benchmark/`](benchmark/).

Benchmarking surfaced two real bugs and one architecture trade-off, all fixed or characterized below.

---

## Starting point: what was missing

Before this round, ezthrottle-local mirrored Aquifer's file structure but had real gaps:

- **No crash durability.** Pure ETS — kill the BEAM node, every queued job is gone.
- **No admission control.** No memory ceiling, no shedding, no 429s.
- **A duplicate-detection race.** `check_or_insert/1` did `:ets.lookup` then a separate `:ets.insert` — non-atomic, so two concurrent requests with the same idempotent key could both insert. Same class of bug Aquifer's `CheckOrInsert` had, found independently here.
- **No client-facing account-queue header.** Isolation could only be toggled by the upstream's response header, not the client's request.
- **Only its own header namespace** — no `X-Aqueduct-*` compatibility.

All five are now fixed.

---

## 1. Mnesia durability

Replaced ETS with Mnesia `disc_copies`. Two fixes were needed before durability was actually real:

**Startup ordering.** `:mnesia` was auto-started by OTP before the app could configure its directory. Fixed by moving it to `included_applications` and starting it explicitly after configuring `:dir`.

**Mnesia doesn't flush per-transaction by default.** `disc_copies` tables live in RAM, flushed to disk only every 100 writes or 3 minutes. Confirmed empirically:

```
write: {:atomic, :ok}
# kill -9 immediately after, restart
read_after_crash: {:atomic, []}   # the write is gone
```

`:mnesia.dump_log()` after the write fixes it:

```
sync_write: {:atomic, :ok}
dump_log: :dumped
# kill -9 immediately after, restart
read_after_crash: {:atomic, [{:foo, "a", "hello"}]}   # survives
```

Flushing on every write reintroduces a real latency cost (see §3), so the shipped design batches the flush on a timer instead (`EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS`, default 100ms) — bounding loss to that interval on a crash rather than eliminating it. Verified on Fly.io: 30 jobs enqueued, machine `SIGKILL`'d mid-drain:

```
jobs enqueued: 30 | completed: 30 | failed: 0 | still queued: 0 | lost: 0
PASS: all 30 jobs survived the crash and drained to a real terminal state
```

Matches Aquifer's own 30/30 result.

---

## 2. The concurrency race

`check_or_insert`'s lookup-then-insert was non-atomic. Fixed by wrapping both in one `:mnesia.sync_transaction`. Covered by `idempotent_store_test.exs` — 50 concurrent unique-key inserts, none misreported as duplicates.

Same shape of bug as Aquifer's `CheckOrInsert` (a different race there — `SELECT`-after-`INSERT OR IGNORE`), found independently, not copied over.

---

## 3. Admission control

`EzthrottleLocal.Admission` mirrors Aquifer's `admission.go`: memory/body/DB-size limits, exponential `Retry-After` backoff. `GET /health` reports a live snapshot.

This is where the per-write Mnesia flush cost showed up. 150 req/s for 45s, before the batched-flush fix:

```
Success 73.23% | Latencies mean 11.292s, p99 30.002s | Memory ~105MB
```

Bottleneck was disk-flush timeouts, not memory — admission control never got a clean shot at shedding. After the 100ms batched flush, identical test:

```
Success 100.00% | Latencies mean 76.031ms, p99 209.721ms | Memory ~99MB
```

Mean latency: 11.3s → 76ms.

---

## 4. Throughput ceiling

With the batched flush, a ramp against the same tier:

| Rate | Result |
|------|--------|
| 50/s | 100% success, mean 69.6ms, p99 181ms |
| 150/s | 100% success, mean 76ms, p99 210ms |
| 400/s | 100% success, mean 93ms, p99 372ms |
| 600/s | 100% success, mean 145ms, p99 626ms |
| 800/s | 100% success, latency degrading — mean 1.7s, p99 10.3s |
| 1000/s | 97.98% success — first real failures (`502`s), memory to 294MB |

Real ceiling: 800-1000 req/s on 1 shared vCPU. That's notably higher than Aquifer's post-fix ~400 req/s ceiling on the identical tier. Not fully isolated, but the likely reason: BEAM gives each request its own process instead of contending for a shared connection pool, and Mnesia's RAM-resident table doesn't have SQLite's single-writer lock contention.

**Flush interval — is longer always better?** No. 250ms was worse than 100ms at both rates tested:

| Rate | 100ms flush | 250ms flush |
|------|-------------|-------------|
| 800/s | mean 1.7s, p99 8.1s | mean 3.5s, p99 13.0s |
| 1000/s | 97.98% success | 88.37% success |

Longer intervals mean bigger, more disruptive flush batches — a sweet spot, not a monotonic improvement. 100ms stays the default.

**CPU cores (100ms flush held constant):**

| Rate | 1 vCPU | 4 vCPUs |
|------|--------|---------|
| 800/s | mean 1.7s, p99 8.1s | mean 529ms, p99 1.76s |
| 1000/s | 97.98% success | 100% success |
| 1500/s | *(not tested)* | 67.48% success |
| 2000/s | *(not tested)* | 0% — total collapse |

More cores helped substantially, unlike the flush interval — the real ceiling moved to somewhere between 1000-1500 req/s.

**Drain time**: same story as Aquifer — bound by configured dispatch pace (2 RPS default), not machine resources.

---

## 5. Multi-tenant fairness

`fairness.sh` surfaced a second version of Aquifer's own bug: `X-Aqueduct-Account-Queue: enabled` on the job-creation request had no effect — the quiet tenant's jobs took 35-52s each, stuck behind a noisy tenant's flood. Cause: isolation could only be toggled by the upstream's response header, not the client's request.

Fixed by adding request-header parsing in `job_controller.ex`, threaded to `UrlActor.enable_account_queue/1`. Verified with a white-box test and a live `fairness.sh` re-run:

```
quiet jobs: 5s, 5s, 3s, 2s, 1s
```

Matches Aquifer's post-fix result (1-5s) almost exactly.

**Security note:** literal pace (RPS/MaxConcurrent) is only ever settable from the upstream's response headers, never the job-creation request, in either system — confirmed by direct code review. The account-queue toggle only changes which queue a tenant lands in, not the rate itself.

---

## Reproducing these results

```bash
cd benchmark
./throughput.sh <target-url> 50 30s
./burst.sh <target-url> 10 100
./admission_degradation.sh <target-url> 150 45s
./crash_recovery.sh <target-url> <fly-app-name> 30
./fairness.sh <target-url> 100
```

Pointed at `ezthrottle-local.fly.dev` by default.
