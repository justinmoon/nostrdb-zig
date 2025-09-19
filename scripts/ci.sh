#!/usr/bin/env bash
set -euo pipefail

echo "=== NostrDB Zig CI ==="

if [[ ! -f build.zig ]]; then
  echo "Run from repo root"
  exit 1
fi

echo "→ Zig version"
zig version || true

echo "→ Format check"
zig fmt --check .

echo "→ Ensure nostrdb sources (flake input copy)"
if [[ ! -f nostrdb/src/nostrdb.c ]]; then
  echo "nostrdb is expected to be materialized by the Nix build phases"
fi

echo "→ Build + test"
zig build -Doptimize=Debug
zig build test -Doptimize=Debug

echo "✓ CI OK"
