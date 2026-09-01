#!/usr/bin/env bash
# Deploys two PRIVATE-ONLY Fly apps for the cross-region /proxy redirect
# test, fixed names (mirrors aquifer/tests/region-redirect and
# ezthrottle-local's own real fly.toml naming): an ezthrottle-local test
# instance with machines in two real regions, and aqueduct-runner/recorder
# as a controllable fake upstream + webhook receiver. Neither app has an
# [http_service]/[[services]] block -- no public exposure at all, driven
# entirely via `fly proxy`. Destroyed at the end of a full
# `make region-redirect-e2e` run (region-redirect-destroy); safe to do
# since there's no public HTTPS/TLS cert involved for either app to
# re-provision on the next run. State (app names, machine id, regions) is
# written to .state so test.sh/destroy.sh can pick up the same deployment.
#
# Usage: FLY_ORG=ezthrottle ./deploy.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/lib.sh"

: "${FLY_ORG:?FLY_ORG is required, e.g. FLY_ORG=ezthrottle make region-redirect-deploy}"
REGION_1="${APP_REGION_1:-iad}"
REGION_2="${APP_REGION_2:-ord}"

if [ -f "$STATE_FILE" ]; then
  echo "error: $STATE_FILE already exists -- run 'make region-redirect-destroy' first" >&2
  exit 1
fi

if [ ! -d "$RECORDER_DIR" ]; then
  echo "error: recorder not found at $RECORDER_DIR (expects aqueduct-runner as a sibling of this repo, or set AQUEDUCT_RUNNER_DIR)" >&2
  exit 1
fi

fly auth whoami > /dev/null 2>&1 || { echo "error: not logged in to Fly -- run 'flyctl auth login' first" >&2; exit 1; }

# Fixed names (not a random per-run suffix) -- these apps stay private-only
# (no [[services]]/[http_service] block, never internet-routable regardless
# of name), so there's no public DNS/TLS cert to worry about on repeated
# destroy+recreate, unlike a public Fly app.
APP_NAME="ezthrottle-local-redirect-test"
RECORDER_APP="ezthrottle-local-redirect-recorder"
if fly apps list --org "$FLY_ORG" 2>/dev/null | grep -q "$APP_NAME\|$RECORDER_APP"; then
  echo "error: $APP_NAME or $RECORDER_APP already exists in org $FLY_ORG -- run 'make region-redirect-destroy' first" >&2
  exit 1
fi

# flyctl resolves a relative `dockerfile =` path (and the default,
# unconfigured Dockerfile lookup) against the fly.toml's own directory, not
# the WORKING_DIRECTORY positional -- confirmed the hard way while building
# Aquifer's own version of this test. The generated configs live directly
# inside each app's real build context (repo root / recorder dir), under a
# name distinct enough not to collide with anything, and get cleaned up on
# exit regardless of success or failure.
APP_CONFIG="$REPO_ROOT/fly.region-redirect-test.toml"
RECORDER_CONFIG="$RECORDER_DIR/fly.region-redirect-test.toml"
cleanup_configs() { rm -f "$APP_CONFIG" "$RECORDER_CONFIG"; }
trap cleanup_configs EXIT

SECRET_KEY_BASE="$(openssl rand -base64 48)"

echo "== Deploying $APP_NAME (private-only, regions: $REGION_1,$REGION_2) =="

cat > "$APP_CONFIG" <<EOF
app = "$APP_NAME"
primary_region = "$REGION_1"

[build]

[env]
  PHX_SERVER = "true"
  PORT = "$APP_PORT"
  PHX_HOST = "localhost"
  MNESIA_DIR = "/tmp/mnesia"
  EZTHROTTLE_FLY_REGIONS = "$REGION_1,$REGION_2"
  EZTHROTTLE_FLY_POLL_INTERVAL_SECONDS = "5"

[[vm]]
  memory = "512mb"
  cpu_kind = "shared"
  cpus = 1
EOF
# Deliberately NO [http_service]/[[services]] block -- private 6PN
# connectivity works regardless of it (any port the app listens on is
# reachable via <region>.$APP_NAME.internal from other machines in this
# org), but omitting it means Fly's public edge proxy has nothing to route
# to this app at all. See API.md's "Cross-region redirect" section.

fly apps create "$APP_NAME" --org "$FLY_ORG"
fly secrets set --app "$APP_NAME" --stage SECRET_KEY_BASE="$SECRET_KEY_BASE" > /dev/null
fly deploy "$REPO_ROOT" --config "$APP_CONFIG" --app "$APP_NAME" --ha=false -y

echo "== Adding a second machine in $REGION_2 =="
ORIGIN_MACHINE_ID="$(fly machine list --app "$APP_NAME" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
fly machine clone "$ORIGIN_MACHINE_ID" --app "$APP_NAME" --region "$REGION_2"

echo "== Deploying $RECORDER_APP (private-only, $REGION_1) =="
cat > "$RECORDER_CONFIG" <<EOF
app = "$RECORDER_APP"
primary_region = "$REGION_1"

[build]

[[vm]]
  memory = "256mb"
  cpu_kind = "shared"
  cpus = 1
EOF
fly apps create "$RECORDER_APP" --org "$FLY_ORG"
fly deploy "$RECORDER_DIR" --config "$RECORDER_CONFIG" --app "$RECORDER_APP" --ha=false -y

echo "== Waiting for both apps to report healthy machines =="
for app in "$APP_NAME" "$RECORDER_APP"; do
  for i in $(seq 1 30); do
    state="$(fly machine list --app "$app" --json | python3 -c 'import json,sys; ms=json.load(sys.stdin); print(",".join(m["state"] for m in ms))' 2>/dev/null || echo "")"
    echo "  $app: $state"
    if [ -n "$state" ] && ! echo "$state" | grep -qv "started"; then
      break
    fi
    sleep 5
  done
done

cat > "$STATE_FILE" <<EOF
APP_NAME="$APP_NAME"
RECORDER_APP="$RECORDER_APP"
ORIGIN_MACHINE_ID="$ORIGIN_MACHINE_ID"
REGION_1="$REGION_1"
REGION_2="$REGION_2"
EOF

echo ""
echo "== Deployed. State saved to $STATE_FILE =="
echo "   Run 'make region-redirect-test' next, then 'make region-redirect-destroy' when done."
