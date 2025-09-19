- If you want to test out nix builds or debug issues on linux, you can `ssh hetzner` and experiment there

Fixing macOS + Nix “darwin.apple_sdk_11_0 has been removed”

- Symptom
  - Nix eval/build on macOS fails with: “darwin.apple_sdk_11_0 has been removed as it was a legacy compatibility stub.”
  - Or C compilation on macOS fails with missing header: Security/SecRandom.h.

- Root cause
  - Newer nixpkgs removed legacy darwin.* aliases. Referencing them (directly or indirectly) throws during evaluation.
  - In Nix sandboxes on macOS, Apple SDK headers/frameworks aren’t visible by default, so compiling sources that include Security/SecRandom.h fails unless the SDK paths are provided explicitly.

- What we did in this repo
  - We added build/apple_sdk.zig and call configureAppleSdk for macOS builds (commit 72027cb “Configure Apple SDK for macOS builds”). It asks Zig to discover the local SDK when building outside Nix.
  - For Nix builds, apple_sdk.zig also honors these environment variables to avoid probing Xcode:
    - APPLE_SDK_FRAMEWORKS: e.g. $(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks
    - APPLE_SDK_SYSTEM_INCLUDE: e.g. $(xcrun --sdk macosx --show-sdk-path)/usr/include
    - APPLE_SDK_LIBRARY: e.g. $(xcrun --sdk macosx --show-sdk-path)/usr/lib
    - APPLE_SDK_LIBC_FILE: optional path to a libc.txt if you have one (usually not needed)

- Known‑good workflows
  - Build on Linux (preferred for Nix):
    - nix run .#ssr-demo -- --db-path ./demo-db --port 8080
  - Build on macOS without Nix (let Zig find Xcode):
    - zig build
  - Build on macOS inside Nix (if you must):
    1) Ensure Xcode CLTs are installed: xcode-select --install
    2) Export SDK env before invoking Zig/Nix:
       export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
       export APPLE_SDK_FRAMEWORKS="$SDKROOT/System/Library/Frameworks"
       export APPLE_SDK_SYSTEM_INCLUDE="$SDKROOT/usr/include"
       export APPLE_SDK_LIBRARY="$SDKROOT/usr/lib"
    3) Then build (dev shell): nix develop && zig build

- Avoid these pitfalls
  - Don’t reference legacy nixpkgs attributes like darwin.apple_sdk_11_0 in Nix expressions; they throw on recent nixpkgs.
  - Don’t rely on Apple SDK discovery inside Nix without providing APPLE_SDK_* vars; probing fails in the sandbox.

- Quick diagnosis
  - If you see “darwin.apple_sdk_11_0 has been removed”, a Nix expression is touching legacy darwin.*; remove/replace that reference.
  - If you see “Security/SecRandom.h file not found”, provide APPLE_SDK_* env vars or build outside Nix on macOS.

- History
  - Initial fix: 72027cb (Configure Apple SDK for macOS builds) introduced build/apple_sdk.zig.
  - Recurring: When nixpkgs updated, the legacy darwin.* aliases were removed; we avoid those in Nix and, on macOS, rely on either Zig’s native discovery or APPLE_SDK_* env variables.

Flake Hygiene (keep it short)

- Principle
  - Keep flake.nix readable. Move long shell logic to scripts/; avoid embedding large heredocs.

- What we changed
  - Moved CI logic to scripts/ci.sh and reference it via writeShellScriptBin.
  - Limited Nix packaging to Linux to avoid macOS SDK complexity in-flake. On macOS, use zig build directly.
  - NixOS module and nginx example live under nix/ for clarity.

- Usage
  - Linux: nix run .#ssr-demo -- --db-path /var/lib/nostrdb-ssr --port 8080
  - macOS: zig build ssr-demo && ./zig-out/bin/ssr-demo --db-path ./demo-db --port 8080
