#!/usr/bin/env bash
set -euo pipefail

echo "=== NostrDB Zig CI ==="
echo ""

# Ensure we're in the project directory (has build.zig)
if [ ! -f "build.zig" ]; then
  echo "Error: build.zig not found. Please run from project root."
  exit 1
fi

echo "→ Checking Zig version..."
if ! command -v zig >/dev/null 2>&1; then
  echo "zig not found in PATH. Ensure you run via 'nix run .#ci' or have zig installed."
  exit 1
fi
zig version
echo ""

# Prefer CC/AR from PATH if available, else fall back to stdenv defaults set by the Nix wrapper
export CC="${CC:-$(command -v cc || true)}"
export AR="${AR:-$(command -v ar || true)}"

# On Linux, help Zig find a basic libc if necessary
if [[ "${OSTYPE:-}" == linux* ]]; then
  export ZIG_LIBC_TXT=$(mktemp)
  cat > "$ZIG_LIBC_TXT" << 'LIBC_EOF'
include_dir=/usr/include
sys_include_dir=/usr/include
crt_dir=/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
LIBC_EOF
  echo "Created libc config at $ZIG_LIBC_TXT"
  # Ensure zig picks this up during build/cc
  export ZIG_LIBC="$ZIG_LIBC_TXT"
fi
echo ""

echo "→ Formatting check..."
echo "Checking if code is properly formatted..."
if ! zig fmt --check . 2>/dev/null; then
  echo "✗ Code formatting issues found!"
  echo "  Run 'zig fmt .' to fix formatting"
  exit 1
fi
echo "✓ Code formatting OK"
echo ""

echo "→ Ensuring nostrdb sources are present..."
if [ -f "nostrdb/src/nostrdb.c" ]; then
  echo "✓ nostrdb sources already present"
else
  echo "nostrdb submodule not present; attempting https clone..."
  # First, try submodule with https override
  git config --global url.https://github.com/.insteadof ssh://git@github.com/ || true
  git config --global url.https://github.com/.insteadof git@github.com: || true
  if git submodule update --init --recursive; then
    echo "✓ submodule initialized via https override"
  else
    echo "Submodule init failed; falling back to direct clone of megalith branch"
    rm -rf nostrdb || true
    git clone --depth 1 --branch megalith https://github.com/justinmoon/nostrdb.git nostrdb
  fi
fi

# Validate required C dependencies in submodule
if [ ! -f "nostrdb/deps/lmdb/mdb.c" ] || [ ! -f "nostrdb/deps/lmdb/midl.c" ]; then
  echo "✗ LMDB sources not found under nostrdb/deps/lmdb"
  exit 1
fi
echo "✓ LMDB headers and sources found"
echo ""

echo "→ Building (debug) ..."
# Nix injects flags that Zig's C stage may not understand; sanitize them
unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS || true
zig build
echo "✓ Build OK"
echo ""

echo "→ Building megalith + ssr-demo ..."
zig build megalith
zig build ssr-demo
echo "✓ megalith and ssr-demo built"
echo ""

echo "→ Running tests (includes smoke) ..."
zig build test
echo "✓ Tests passed"
echo ""

echo "→ Additional checks..."
TODO_COUNT=$(grep -r "TODO\|FIXME" --include="*.zig" . 2>/dev/null | wc -l || echo "0")
if [ "$TODO_COUNT" -gt 0 ]; then
  echo "ℹ Found $TODO_COUNT TODO/FIXME comments"
fi
UNREACHABLE_COUNT=$(grep -r "unreachable" --include="*.zig" . 2>/dev/null | wc -l || echo "0")
if [ "$UNREACHABLE_COUNT" -gt 0 ]; then
  echo "ℹ Found $UNREACHABLE_COUNT uses of 'unreachable'"
fi

echo ""
echo "=== ✓ CI passed successfully! ==="
