#!/usr/bin/env bash
set -euo pipefail

# Simple end-to-end smoke for the SSR app using real relays.
#
# What it does:
#  - Builds ssr-demo
#  - Starts it with a fresh LMDB dir and a small default relay set
#  - Loads /timeline?npub=... to auto-start ingestion (first view)
#  - Polls /status?npub=... until events_ingested > 0 or timeout
#  - Asserts at least one post renders in the HTML
#
# Env vars:
#  NPUB      - target npub (default: Justin's npub)
#  PORT      - SSR port (default: 8085)
#  TIMEOUT_S - overall wait in seconds (default: 120)
#  RELAYS    - comma-separated relay URLs (optional; defaults provided)
#  WS_ORIGIN - Origin header to send in WS handshake (default: https://nostrdb-ssr.local)

NPUB="${NPUB:-npub1zxu639qym0esxnn7rzrt48wycmfhdu3e5yvzwx7ja3t84zyc2r8qz8cx2y}"
PORT="${PORT:-8085}"
TIMEOUT_S="${TIMEOUT_S:-120}"
RELAYS_DEFAULT="wss://relay.damus.io,wss://nostr.wine,wss://nos.lol,wss://relayable.org"
RELAYS="${RELAYS:-$RELAYS_DEFAULT}"
WS_ORIGIN="${WS_ORIGIN:-https://nostrdb-ssr.local}"

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG_DIR="$ROOT_DIR/.e2e-logs"
mkdir -p "$LOG_DIR"
SSR_LOG="$LOG_DIR/ssr.log"

DB_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ssr-e2e-db)
cleanup() {
  if [[ -n "${SSR_PID:-}" ]]; then
    kill "$SSR_PID" >/dev/null 2>&1 || true
    wait "$SSR_PID" 2>/dev/null || true
  fi
  rm -rf "$DB_DIR"
}
trap cleanup EXIT

echo "[e2e] Building ssr-demo..."
pushd "$ROOT_DIR" >/dev/null
zig build ssr-demo -Doptimize=Debug >/dev/null
popd >/dev/null

echo "[e2e] Starting SSR (port $PORT, db $DB_DIR, origin $WS_ORIGIN)..."
"$ROOT_DIR/zig-out/bin/ssr-demo" --db-path "$DB_DIR" --port "$PORT" --relays "$RELAYS" --ws-origin "$WS_ORIGIN" > "$SSR_LOG" 2>&1 &
SSR_PID=$!

# Wait for SSR HTTP to respond
BASE="http://127.0.0.1:$PORT"
echo -n "[e2e] Waiting for SSR to listen"
for i in {1..50}; do
  if curl -fsS "$BASE/" >/dev/null 2>&1; then
    echo " ... ready"
    break
  fi
  echo -n "."
  sleep 0.1
done

echo "[e2e] Triggering timeline view for NPUB: $NPUB"
curl -fsS "$BASE/timeline?npub=$NPUB" >/dev/null || true

echo "[e2e] Polling status until events arrive (timeout ${TIMEOUT_S}s)"
DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
EVENTS=0
PHASE="initial"
LAST_ERR=""
while :; do
  # If SSR process died, fail fast with logs
  if ! kill -0 "$SSR_PID" >/dev/null 2>&1; then
    echo "[e2e] SSR process exited unexpectedly"
    echo "--- SSR LOG (tail) ---"
    tail -n 200 "$SSR_LOG" || true
    exit 1
  fi

  NOW=$(date +%s)
  if (( NOW >= DEADLINE )); then
    echo "[e2e] Timeout waiting for events. Phase=$PHASE Events=$EVENTS"
    echo "--- Status (per-relay) ---"
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<PY 2>/dev/null || true
import sys, json
try:
  d=json.loads('''$STATUS_JSON''')
  relays=d.get('relays',[])
  for r in relays:
    url=r.get('url')
    attempts=r.get('attempts')
    eose=r.get('eose')
    last_err=r.get('last_error')
    last_ms=r.get('last_change_ms')
    print(f"- {url} attempts={attempts} eose={eose} last_ms={last_ms} err={last_err}")
except Exception as e:
  pass
PY
    else
      echo "$STATUS_JSON" | sed -n 's/.*\"url\":\"\([^"]*\)\".*/\1/p' | sed 's/^/- /'
    fi
    echo "--- SSR LOG (tail) ---"
    tail -n 200 "$SSR_LOG" || true
    exit 1
  fi

  STATUS_JSON=$(curl -fsS "$BASE/status?npub=$NPUB" || echo '{}')
  # Prefer python JSON parsing if available
  if command -v python3 >/dev/null 2>&1; then
    EVENTS=$(python3 - <<PY 2>/dev/null || echo 0
import sys, json
try:
  d=json.loads(sys.stdin.read())
  print(int(d.get('events_ingested',0)))
except Exception:
  print(0)
PY
    <<<"$STATUS_JSON")
    PHASE=$(python3 - <<PY 2>/dev/null || echo initial
import sys, json
try:
  d=json.loads(sys.stdin.read())
  print(d.get('phase','initial'))
except Exception:
  print('initial')
PY
    <<<"$STATUS_JSON")
    LAST_ERR=$(python3 - <<PY 2>/dev/null || echo
import sys, json
try:
  d=json.loads(sys.stdin.read())
  v=d.get('last_error')
  print(v if v else '')
except Exception:
  print('')
PY
    <<<"$STATUS_JSON")
  else
    # Fallback: regex-ish extraction
    EVENTS=$(echo "$STATUS_JSON" | sed -n 's/.*"events_ingested":\([0-9][0-9]*\).*/\1/p' | head -n1)
    PHASE=$(echo "$STATUS_JSON" | sed -n 's/.*"phase":"\([^"]*\)".*/\1/p' | head -n1)
    LAST_ERR=""
  fi

  echo "[e2e] phase=$PHASE events=$EVENTS${LAST_ERR:+ error=$LAST_ERR}"
  if [[ "${EVENTS:-0}" -ge 1 ]]; then
    break
  fi
  sleep 1
done

echo "[e2e] Fetching rendered HTML to assert at least 1 post"
HTML=$(curl -fsS "$BASE/timeline?npub=$NPUB") || {
  echo "[e2e] Failed to fetch timeline HTML"
  exit 1
}

NOTES=$(echo "$HTML" | grep -c 'class="note"' || true)
if [[ "$NOTES" -lt 1 ]]; then
  echo "[e2e] Expected at least 1 rendered post, got $NOTES"
  echo "--- SSR LOG (tail) ---"
  tail -n 200 "$SSR_LOG" || true
  exit 1
fi

echo "[e2e] PASS: events_ingested=$EVENTS, notes_rendered=$NOTES"
exit 0
