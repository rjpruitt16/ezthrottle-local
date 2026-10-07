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

## 6. GPU inference and the retry tax (RunPod/vLLM)

Ported from Aquifer's identical benchmark (see its `benchmark.md`) after porting the underlying feature: `lib/ezthrottle_local/orca.ex` reads vLLM's `kv_cache_usage_perc` from the `endpoint-load-metrics` response header as a fallback pacing signal, same thresholds as Aquifer's `orca.go`. Same GPU, same vLLM instance, same job payload shape (`POST /jobs` is schema-identical between the two).

**Same offered load (40 req/s for 30s), direct-to-vLLM vs. through EZThrottle:**

| | Direct | Through EZThrottle |
|---|---|---|
| Client success | 100% | 100% |
| Client mean latency | 11.4s | 5.9ms |
| Peak vLLM-side queue depth | 447 waiting | 0 waiting |
| Peak `kv_cache_usage_perc` | 70.1% | 1.9% |

Ingest absorbs the burst exactly like Aquifer's — 100% success, single-digit-millisecond latency, full 40 req/s accepted instantly. But actual dispatch to vLLM never went above **1 concurrent request**, and stayed there for the whole run.

**Why, and a real gap this surfaced:** unlike Aquifer, which has a per-upstream `max_concurrent` set via `CONFIG_PATH`, EZThrottle Local's `max_concurrent` has no config knob at all — every `UrlActor` starts at a hardcoded `1` and only rises if the upstream sends back an explicit `X-Aqueduct-Max-Concurrent`/`X-EZTHROTTLE-MAX-CONCURRENT` header. vLLM doesn't send that (it only speaks ORCA), so concurrency never left 1. That's an extremely conservative default in one sense — vLLM was never at real risk here regardless of the burst size — but it also means the ORCA rps signal had no room to matter: with only one in-flight request at a time, `kv_cache_usage_perc` never came close to the 70% threshold that would trigger a pacing cut.

`orca.ex` itself is correct and covered by unit tests (`test/ezthrottle_local/orca_test.exs`, 8 tests mirroring Aquifer's `orca_test.go` exactly) — the mechanism is proven at the unit level; this run just didn't have the concurrency headroom to exercise it end-to-end against a real GPU the way Aquifer's did. Filed as [issue #7](https://github.com/rjpruitt16/ezthrottle-local/issues/7) to add a `default_max_concurrent` config knob (mirroring `default_rps`, which had the same gap and was fixed as part of this port) rather than building it unprompted.

---

## 7. Per-job overhead (`make perf`)

The throughput ceiling above measures intake only: dispatch ran at the default 2 RPS, so it never tested receiving and sending at the same time. `make perf` does. It runs in-process against a local upstream and webhook receiver that answer instantly and advertise a very high rate, and mirrors Aquifer's `make perf` so the two can be compared on one machine.

- **Job latency** sends one job at a time and splits its trip into accept (validated and stored, i.e. `POST /jobs` returns), queue (accepted until the upstream receives it) and total.
- **Pipeline throughput** has 8 concurrent callers submit 2000 jobs and reports how many per second are accepted, dispatched, completed and have their webhook delivered. It runs on an empty store, then with 100k finished jobs retained, since completed jobs are kept for 30 minutes and a busy node always carries many.

Baseline, 2026-10-06, Apple M3 Max laptop:

| | accept | queue | total | jobs/s, empty | jobs/s, 100k retained |
|---|---:|---:|---:|---:|---:|
| Before (`counts/0` scanned the jobs table on every dispatch; `:in_flight` written per job) | 0.51 ms | 0.45 ms | 0.96 ms | 1104 | 287 |
| After (running counters; no `:in_flight` write) | 0.48 ms | 0.41 ms | 0.89 ms | 1380 | 713 |

Single-job latency barely moves, since an empty table is cheap to scan. Throughput with retained jobs is where the scan hurt: 2.5x faster after the fix. Even after it, 100k retained jobs still roughly halve throughput. Part of that is Mnesia's own disk dump: on this machine `dump_log` averages about 2.4 ms on an empty table and 6.6 ms at 100k rows, with spikes over 80 ms when it rewrites the table file. That isn't fully pinned down yet.

These numbers aren't directly comparable to Aquifer's Pebble row. EZThrottle acknowledges a job before it reaches disk (flushed every 100ms, see section 1), while Pebble syncs every write.

---

## 8. Capacity per machine, end to end (Fly.io, 2026-10-07)

Same harness as Aquifer's benchmark.md section 12:
- **Target:** one ezthrottle-local machine with a volume.
- **Load generator:** Aquifer's `benchmark/loadgen` on a separate machine. It ramps `POST /jobs` across 50 users and also serves as the upstream and the webhook receiver, both answering instantly.
- **Webhooks:** every job also delivers a webhook.
- **Config:** `EZTHROTTLE_DEFAULT_RPS=100000`, 100ms Mnesia flush (the default), production log level.

This measures accepting, dispatching, completing and delivering each job's webhook at the same time, unlike section 4, which measured intake only (dispatch at 2 RPS). The two aren't comparable.

| Machine | Sustained jobs/s | p99, submit to webhook | Past the ceiling |
|---|---:|---:|---|
| performance-1x | ~400 (550 on one run) | ~0.6 s | collapses at 700 |
| performance-2x | ~700 | 31 ms | collapses at 1,000 |
| performance-4x | ~1,500 | 0.5 s | collapses at 2,000 |

Before the changes below, the same test on performance-1x accepted about 60 jobs/s, and the node was OOM-killed within a minute.

**What was in the way.** Each item was found by sampling the stacks of running processes and checking mailbox lengths on the live node.

| Problem | Fix |
|---|---|
| Every submission ran its Mnesia insert inside the domain's `AccountQueue` process, which the domain's `UrlActor` called synchronously, so a domain inserted one job at a time | On a standalone node the insert runs in the request's own process |
| The insert was a Mnesia `sync_transaction` through the lock manager | An ETS `insert_new` gate decides the winner; rows are dirty-written (still logged, still flushed every 100ms) |
| Fair admission called every queue for a snapshot on each submission | Each queue keeps its backlog in an ETS counter |
| `actor_for` went through the registry process on every submission | Read the actor table directly |
| Every job was registered with Syn (two more process hops), even with no cluster | Skipped on standalone nodes |
| Admission listed and stat-ed the Mnesia directory, and when the cached reading expired every request did it at once, all through OTP's single `:file_server` | Single-flight refresh with an atomic compare-and-swap |
| Admission state was an Agent updated on every request | `:atomics` |
| Queue position events were broadcast for every queued job, blocking the queue process | Only for jobs with a stream subscriber (standalone) |
| `syn` lookups and `Process.alive?` checks on busy processes wait behind their mailboxes | Use the monitored maps that already track them |
| `:httpc` sent every request through one manager process | Finch connection pools |
| Every webhook to a receiver without L8 re-probed `/.well-known/l8` | Remembered for 5 minutes |
| Every `/jobs` request logged at `:info` | Hot API routes log at `:debug` |
| Every finished job wrote a drain event, with drain mode off | Only with drain mode on |

**Still open.**
- **Overload collapses instead of shedding.** Past the ceiling, requests queue in the domain's `UrlActor` mailbox until clients time out, rather than getting `429`s. Admission control looks at queue backlog, not at how long requests wait to be admitted.
- **One process per domain.** Every job for a domain still passes through that domain's `UrlActor`. In this test the upstream and the webhook receiver share one domain, so it carries both.
- **Clustered nodes keep the old path.** The fast path above applies only to standalone nodes. Clusters keep the original queue-owner path, so these numbers don't apply to them.

---

## Reproducing these results

```bash
cd benchmark
./throughput.sh <target-url> 50 30s
./burst.sh <target-url> 10 100
./admission_degradation.sh <target-url> 150 45s
./crash_recovery.sh <target-url> <fly-app-name> 30
./fairness.sh <target-url> 100

# GPU retry tax -- needs a real vLLM instance (RunPod or otherwise),
# not part of the regular pass:
./gpu_retry_tax.sh <vllm-url> <ezthrottle-url> 40 40 300
```

Pointed at `ezthrottle-local.fly.dev` by default.
