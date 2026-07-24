# Benchmarks — and a comparison against Aquifer

Real runs against a live deployment (`ezthrottle-local.fly.dev`), not simulated numbers — the same `shared-cpu-1x` / 512MB Fly.io tier, same region (`iad`), and the same benchmark methodology used for [Aquifer's own benchmark.md](https://github.com/rjpruitt16/aquifer/blob/main/benchmark.md), Aquifer being the Go/SQLite sibling this project mirrors. Scripts are in [`benchmark/`](benchmark/), ported directly from Aquifer's with only the target defaults changed.

This write-up follows the same investigation shape as Aquifer's: what started as "does it work" benchmarking surfaced two real bugs and one genuine architecture trade-off, all fixed or characterized below.

---

## Starting point: what was missing

Before this round of work, ezthrottle-local was a close architectural mirror of Aquifer (same file-for-file shape: `account_queue.ex`/`account_queue.go`, `url_actor.ex`/`url_worker.go`, `idempotent_store.ex`/`store.go`) but with real gaps:

- **No crash durability at all.** Pure ETS — kill the BEAM node and every queued job is gone, not degraded, gone. Disclosed honestly in the project's own README ("EZThrottle Cloud picks up where this leaves off"), but a real gap versus Aquifer's SQLite-backed durability.
- **No admission control.** `job_controller.ex` always accepted new work; no memory ceiling, no shedding, no 429s.
- **A duplicate-detection race.** `IdempotentStore.check_or_insert/1` did `:ets.lookup` then a separate `:ets.insert` — two non-atomic steps. Under real concurrency, two requests with the same idempotent key could both see an empty lookup and both proceed to insert, silently defeating the one guarantee that function exists to provide. The same class of bug Aquifer's own `CheckOrInsert` had (fixed earlier this session) — found here independently, not copied over.
- **No client-facing account-queue header.** Per-tenant isolation could only be toggled by the upstream's *response* header or static config — there was no way for the client submitting a job to request isolation directly, unlike Aquifer's `X-Aqueduct-Account-Queue` request header.
- **Only its own header namespace.** `X-EZThrottle-*` only, no `X-Aqueduct-*` protocol compatibility.

All five are now fixed. Two of them (durability, the race) surfaced genuinely new findings along the way, documented below.

---

## 1. Mnesia durability — and a real gap Mnesia itself has by default

Replaced ETS with Mnesia `disc_copies` tables. This was not a drop-in swap — two real problems had to be found and fixed before durability was actually real, not just assumed:

**Startup ordering.** `:mnesia` was listed in `extra_applications`, which OTP auto-starts *before* `EzthrottleLocal.Application.start/2` runs — meaning Mnesia started with its default (unconfigured, effectively RAM-only) directory before our code ever got a chance to set `:dir`. Fixed by moving `:mnesia` to `included_applications` (bundles its code into a release without OTP auto-starting it) and starting it explicitly, after configuring the directory, in `IdempotentStore.ensure_schema!/0`.

**The bigger finding: Mnesia's `disc_copies` doesn't flush per-transaction by default.** `disc_copies` tables live fully in RAM, with the on-disk copy kept current via a transaction log that Mnesia only flushes at its own periodic threshold — by default, every 100 writes *or* every 3 minutes, whichever comes first. A plain (or even `sync_`) transaction commits in memory well before that log entry is actually on disk. Confirmed empirically, in isolation, outside the app entirely:

```
write: {:atomic, :ok}
# kill -9 the process immediately after
# --- restart, same directory ---
read_after_crash: {:atomic, []}   # the write is gone
```

Adding an explicit `:mnesia.dump_log()` after the write fixed it:

```
sync_write: {:atomic, :ok}
dump_log: :dumped
# kill -9 immediately after
# --- restart ---
read_after_crash: {:atomic, [{:foo, "a", "hello"}]}   # survives
```

This is not a Mnesia bug — it's Mnesia's actual, documented default trade-off (durability vs. write throughput), and it would have made the crash-durability claim quietly false: "survives a graceful shutdown" is not the same guarantee as "survives a crash," and crash survival is the entire point of switching off ETS.

**The cost, and the fix for the cost.** Flushing on every single write reintroduced a real per-request latency tax — see section 3. The final design (`EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS`, default 100ms) batches the flush on a timer instead of forcing it inline per request, bounding the loss window to at most that interval on a true crash rather than eliminating it entirely — the same trade-off SQLite's own `synchronous=NORMAL` already makes (Aquifer doesn't get zero-loss-on-every-write either), and the same one Postgres's `synchronous_commit=off` makes explicitly.

**Verified on real Fly.io infrastructure**, not just locally: 30 jobs enqueued, machine `SIGKILL`'d mid-drain, restarted — with both the strict (per-write) and the batched (100ms) flush modes:

```
jobs enqueued:        30
completed:            30
failed (but tracked): 0
still queued after 60s: 0
not found (lost):      0

PASS: all 30 jobs survived the crash and drained to a real terminal state
```

Matches Aquifer's own 30/30 crash-recovery result exactly.

---

## 2. The concurrency race — found independently, same class of bug as Aquifer's

`check_or_insert`'s lookup-then-insert was non-atomic. Fixed by wrapping both the read and the write in a single `:mnesia.sync_transaction`, which Mnesia's transaction manager serializes correctly (unlike raw `:ets.lookup`/`:ets.insert`, which have no such guarantee). Covered by a new test (`idempotent_store_test.exs`) firing 50 concurrent unique-key inserts and asserting none are misreported as duplicates — stable across repeated runs.

This is the same shape of bug found and fixed in Aquifer's `CheckOrInsert` earlier this session (a `SELECT`-after-`INSERT OR IGNORE` race there, rather than a lookup-then-insert race here) — different mechanism, same underlying lesson: a "check then act" pattern across two separate operations is never actually atomic unless something explicitly makes it so.

---

## 3. Admission control

New `EzthrottleLocal.Admission` module, a direct mirror of Aquifer's `admission.go`: `EZTHROTTLE_MEMORY_LIMIT_MB` / `MAX_BODY_BYTES` / `DB_MAX_BYTES` / `RETRY_AFTER_SECONDS`, same opt-in-by-default semantics, same exponential `Retry-After` backoff (doubles per consecutive rejection, capped at 60s, resets the moment a request is allowed again). `GET /health` reports a live snapshot. Oversized bodies get a `413` via a `BodyLimit` plug that checks `Content-Length` before `Plug.Parsers` reads anything.

**This is also where the per-write Mnesia flush cost showed up concretely.** At 150 req/s for 45s, before the batched-flush fix:

```
Requests      [total, rate, throughput]  6750, 150.02, 65.91
Success       [ratio]                    73.23%
Status Codes  [code:count]               0:1807  201:4943
Latencies     [mean, p99]                11.292s, 30.002s
Memory peaked at ~105MB (well under the 400MB ceiling)
first rejection (429): none observed
```

Memory never got anywhere near the configured ceiling — the bottleneck was connection/request timeouts from the per-write disk flush, not memory pressure, so admission control never got a chance to shed cleanly. After switching to the 100ms batched flush, the identical test:

```
Requests      [total, rate, throughput]  6750, 150.02, 149.80
Success       [ratio]                    100.00%
Status Codes  [code:count]               201:6750
Latencies     [mean, p99]                76.031ms, 209.721ms
Memory peaked at ~99MB
```

Full recovery — mean latency dropped from 11.3s to 76ms.

---

## 4. Throughput ceiling — and how it compares to Aquifer's

With the batched flush in place, a ramp against the same tier:

| Rate | Result |
|------|--------|
| 50/s | 100% success, mean 69.6ms, p99 181ms |
| 150/s | 100% success, mean 76ms, p99 210ms |
| 400/s | 100% success, mean 93ms, p99 372ms |
| 600/s | 100% success, mean 145ms, p99 626ms |
| 800/s | 100% success, but latency degrading — mean 1.7s, p99 10.3s |
| 1000/s | **97.98% success** — first real failures (`502`s, connection resets), memory climbing to 294MB |

So the real ceiling here sits between 800 and 1000 req/s (1 shared vCPU): still fully successful at 800 (just with materially worse tail latency), genuinely breaking down at 1000.

This is a notably higher ceiling than Aquifer's own post-fix numbers on the identical tier — Aquifer's single-SQLite-connection-pool architecture (even after fixing the `SetMaxOpenConns(1)` bug this session) sits at a real ceiling around 400 req/s, with 200 req/s already showing run-to-run variance. A plausible explanation, not yet fully isolated: BEAM's per-request lightweight-process model has no equivalent to a shared connection pool as the serialization point — each request gets its own process, and Mnesia's RAM-resident table doesn't have SQLite's single-writer lock contention in the same way. This is a real, measured difference, not a design guess — but pinning down exactly which piece of the architecture (process model vs. storage engine vs. something else) accounts for the gap would need further isolation than this session did.

### Does the flush interval have a sweet spot, or is "longer is better"?

Tested raising `EZTHROTTLE_MNESIA_FLUSH_INTERVAL_MS` from 100ms to 250ms, expecting further improvement. It didn't — at both rates tested, 250ms was measurably *worse* than 100ms:

| Rate | 100ms flush | 250ms flush |
|------|-------------|-------------|
| 800/s | 100% success, mean 1.7s, p99 8.1s | 100% success, mean **3.5s**, p99 **13.0s** |
| 1000/s | 97.98% success | **88.37%** success, more `502`s |

Not monotonic — there's a sweet spot, not "longer batching is always better." A longer interval means more writes accumulate between flushes, so each individual flush becomes a bigger, more disruptive batch to write out, trading flush *frequency* for flush *size* in a way that made tail latency worse, not better. Same shape of trade-off as Postgres's checkpoint tuning: too-infrequent checkpoints cause bigger I/O spikes at checkpoint time even though they reduce average overhead. 100ms was already on the better side of that curve for this workload; going lower wasn't tested, but going higher clearly wasn't the right direction.

### Scaling with CPU cores (flush interval held at 100ms)

With the ceiling not moving via flush tuning, the next lever tested was raw CPU — same `shared-cpu-1x` machine bumped to 4 shared vCPUs / 1GB:

| Rate | 1 vCPU | 4 vCPUs |
|------|--------|---------|
| 800/s | 100% success, mean 1.7s, p99 8.1s | 100% success, mean **529ms**, p99 **1.76s** |
| 1000/s | 97.98% success (first failures) | **100% success**, mean 1.66s, p99 9.8s |
| 1500/s | *(not tested at 1 vCPU)* | 67.48% success — real failures begin |
| 2000/s | *(not tested at 1 vCPU)* | **0% success** — total collapse, health check itself stopped responding |

Unlike the flush-interval knob, more cores helped cleanly and substantially — 1000 req/s went from "first cracks appearing" to fully clean, and the real ceiling moved from ~800-1000 req/s to somewhere between 1000-1500 req/s. This is the more promising lever of the two tested: CPU headroom directly addresses the actual bottleneck (BEAM scheduling more concurrent requests across more cores), whereas the flush interval was tuning a cost that was already reasonably well-amortized at 100ms.

**Drain time**: identical story to Aquifer — bound by the configured per-domain dispatch pace (2 RPS default here too), not by machine resources.

---

## 5. Multi-tenant fairness — a second version of the exact bug Aquifer had

Running the ported `fairness.sh` first surfaced a gap: sending `X-Aqueduct-Account-Queue: enabled` on the job-creation request had no effect — the quiet tenant's jobs still took 35-52 seconds each, stuck behind the noisy tenant's 100-job flood. Root cause: unlike Aquifer, account-queue mode here could only be toggled by the *upstream's response* header or static config — there was no code path at all for the client's own request header to reach `UrlActor`.

Fixed by adding request-header parsing (`X-Aqueduct-Account-Queue`, falling back to `X-EZThrottle-Account-Queue`) in `job_controller.ex`, threaded through `AccountQueueRegistry.enqueue/2` to `UrlActor.enable_account_queue/1`. Verified two ways: a white-box test (`account_queue_header_test.exs`) asserting directly on `UrlActor`'s internal queue-key state, and a live re-run of `fairness.sh`:

```
quiet job 0: status=completed elapsed=5s
quiet job 1: status=completed elapsed=5s
quiet job 2: status=completed elapsed=3s
quiet job 3: status=completed elapsed=2s
quiet job 4: status=completed elapsed=1s
```

Matches Aquifer's own post-fix fairness result (1-5s) almost exactly.

**On the security question this raised**: literal pace (RPS/MaxConcurrent) is confirmed, by direct code review, to be settable *only* from the upstream's response headers in both Aquifer and ezthrottle-local — never from the job-creation request, in either system. The account-queue toggle is a different axis (which queue a tenant's jobs land in, not the rate itself) — and per-tenant differentiated pacing, where each isolated queue independently follows its own upstream's rate signals, is the intended feature (documented in this project's own README: a premium tenant at 50 RPS and a free tier at 2 RPS, in parallel, unaffected by each other), not a loophole.

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

Each script is the same bash + vegeta + Python shape as Aquifer's, pointed at `ezthrottle-local.fly.dev` by default.
