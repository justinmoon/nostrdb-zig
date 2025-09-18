#!/bin/bash
# Run this on the Hetzner server to debug the CI

cd /tmp
rm -rf test-nostrdb-zig
git clone https://github.com/justinmoon/nostrdb-zig.git test-nostrdb-zig
cd test-nostrdb-zig
git checkout zig-flake-ci
git submodule update --init --recursive

echo "Testing with nix..."
nix develop --command bash -c "zig version"

echo "Testing build with different targets..."
# Try native
nix develop --command bash -c "zig build -Dtarget=native-linux 2>&1 | head -20"

# Try musl
nix develop --command bash -c "zig build -Dtarget=x86_64-linux-musl 2>&1 | head -20"

# Try with glibc
nix develop --command bash -c "zig build -Dtarget=x86_64-linux-gnu 2>&1 | head -20"

# Check what's available
nix develop --command bash -c "which cc && cc --version"
nix develop --command bash -c "ls -la /usr/include/ 2>/dev/null || echo 'No /usr/include'"
nix develop --command bash -c "pkg-config --cflags --libs libc 2>/dev/null || echo 'No pkg-config for libc'"
