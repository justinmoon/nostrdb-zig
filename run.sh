#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOSTRDB_DIR="$ROOT/nostrdb"
EVENT_FILE="$NOSTRDB_DIR/testdata/many-events.json"
DB_DIR="${DB_DIR:-$ROOT/demo-db}"

log() {
    printf '[run] %s\n' "$1"
}

human_bytes() {
    python3 - <<'PY' "$1"
import sys
size = int(sys.argv[1])
units = ['B', 'KB', 'MB', 'GB', 'TB']
value = float(size)
idx = 0
while value >= 1024 and idx < len(units) - 1:
    value /= 1024
    idx += 1
print(f"{value:.1f} {units[idx]}")
PY
}

if [ ! -x "$NOSTRDB_DIR/ndb" ]; then
    log "building ndb CLI"
    (cd "$NOSTRDB_DIR" && make ndb)
fi

if [ ! -f "$EVENT_FILE" ];then
    log "fetching demo events"
    (cd "$NOSTRDB_DIR" && make testdata/many-events.json)
fi

mkdir -p "$DB_DIR"
if [ ! -f "$DB_DIR/data.mdb" ]; then
    log "importing events into $DB_DIR"
    "$NOSTRDB_DIR/ndb" -d "$DB_DIR" --skip-verification import "$EVENT_FILE" &
    import_pid=$!

    monitor_progress() {
        while kill -0 "$import_pid" 2>/dev/null; do
            if [ -f "$DB_DIR/data.mdb" ]; then
                size=$(stat -f%z "$DB_DIR/data.mdb" 2>/dev/null || echo 0)
                human=$(human_bytes "$size")
                log "lmdb size: $human ($size bytes)"
            else
                log "waiting for data.mdb to appear"
            fi
            sleep 5
        done
    }

    monitor_progress &
    monitor_pid=$!
    wait "$import_pid"
    status=$?
    wait "$monitor_pid" 2>/dev/null || true
    if [ $status -ne 0 ]; then
        log "event import failed (exit $status)"
        exit $status
    fi
else
    log "skipping import (data.mdb already present)"
fi

log "building mega"
(cd "$ROOT" && zig build mega)

log "starting server"
exec "$ROOT/zig-out/bin/mega" --db-path "$DB_DIR" "$@"
