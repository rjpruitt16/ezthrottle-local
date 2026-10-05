# AGENTS.md

ezthrottle-local is the Elixir/Phoenix sibling of Aquifer: the same job API, pacing headers, `POST /proxy`, drain mode, and L8, built on OTP (GenServers, Mnesia, Syn). Many modules say "mirrors Aquifer's X"; when porting, read the Aquifer file first.

## Related repos

These repos are developed together and are usually cloned as siblings under one folder (`SAAS/`). Before you search the web or guess, check whether the sibling exists locally at the path below and read it.

| Repo | Local path | GitHub | Role |
|---|---|---|---|
| aquifer | `../aquifer` | https://github.com/rjpruitt16/aquifer | Go load balancer for agentic workloads; reference implementation |
| ezthrottle-local | `../ezthrottle-local` | https://github.com/rjpruitt16/ezthrottle-local | Elixir/Phoenix sibling of Aquifer; kept feature-for-feature in sync |
| l8-protocol | `../l8-protocol` | https://github.com/rjpruitt16/l8-protocol | L8 spec (`index.md`, `spec.json`): handshake, signing, encryption, request schemas |
| aqueduct-runner | `../aqueduct-runner` | https://github.com/rjpruitt16/aqueduct-runner | Cross-repo contract tests (Dagger + Hurl) run against real Aquifer and ezthrottle-local containers |
| canalis-rs | `../canalis-rs` | https://github.com/rjpruitt16/canalis-rs | Rust control plane for Aquifer/ezthrottle-local fleets |

Shared contracts that must stay identical across Aquifer and ezthrottle-local: `X-Aqueduct-*` request/response headers, job JSON shape, idempotency hashing (`sha256(user_id + ":" + key)`, or `sha256("shared\0" + key)` for `idempotency_scope: "shared"`), drain ledger events, `POST /proxy` direct-then-fallback behavior, and L8. A change to any of these in one repo needs the matching change in the other, an update to `l8-protocol` if it touches L8, and ideally a contract test in `aqueduct-runner`.

## Commands

- Tests: `mix test` (runs with a fresh `tmp/mnesia_test_*` directory). `mix compile --warnings-as-errors` should stay clean.
- Formatting: run `mix format` only on files you touch that were already formatter-clean; `l8.ex`, `redirect.ex`, and `l8_controller.ex` use hand-aligned style.
- Python L8 integration: `test/integration/l8_receiver.py` + `test/integration/test_l8.py`. The test config sets the endpoint `server: false`, so start a live server with `MIX_ENV=test mix run --no-start --no-halt -e '...'` after setting the endpoint's `:server` to true.
- Cross-repo contracts: from `../aqueduct-runner`, e.g. `make contract-test-ezthrottle`.

## Where things live

- `lib/ezthrottle_local/job.ex` (`Job.new/1`), `idempotent_store.ex` (`hash_key/1`, Mnesia tables), `account_queue.ex` (`make_request/6`, the upstream dispatch path), `proxy.ex`, `webhook.ex`.
- `lib/ezthrottle_local/l8.ex` and `l8/schemas.ex`: L8 handshake, signing, encryption, request schemas.
- `lib/ezthrottle_local_web/controllers/job_controller.ex`: HTTP glue for `/jobs` and `/proxy`.
- Cluster routing: a request goes to the Syn owner of its (upstream, account queue) before idempotency admission; the account queue key is derived from `user_id`.

## Conventions

- New behavior is opt-in: gate it behind an env flag that defaults off. Background loops and processes should not start at all when their flag is off.
- Work on a feature branch and open a PR for review. Do not push to `main` or merge.
- Commits: no `Co-Authored-By` or `Claude-Session` trailers.
- Docs prose: avoid em dashes outside titles and headings.
- Report failures and limits honestly in PR descriptions; don't overstate results.
