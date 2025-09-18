{
  description = "NostrDB Zig - A Zig wrapper for the NostrDB library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigPkg = zig.packages.${system}."0.15.1";
        
        # Development dependencies
        devDeps = with pkgs; [
          zigPkg
          pkg-config
          # C dependencies for nostrdb
          lmdb
          secp256k1
          # Build tools
          gnumake
          gcc
          cmake
          stdenv.cc
          # Git for fetching submodules
          git
          # For macOS framework linking
        ] ++ lib.optionals pkgs.stdenv.isDarwin [
          darwin.apple_sdk.frameworks.Security
        ];
        
        # CI script that runs all tests and checks
        ciScript = pkgs.writeShellScriptBin "ci" ''
          set -euo pipefail
          
          echo "=== NostrDB Zig CI ==="
          echo ""
          
          # Ensure we're in the project directory
          if [ ! -f "build.zig" ]; then
            echo "Error: build.zig not found. Please run from project root."
            exit 1
          fi
          
          echo "→ Checking Zig version..."
          ${zigPkg}/bin/zig version
          echo ""
          
          echo "→ Formatting check..."
          echo "Checking if code is properly formatted..."
          if ! ${zigPkg}/bin/zig fmt --check . 2>/dev/null; then
            echo "✗ Code formatting issues found!"
            echo "  Run 'zig fmt .' to fix formatting"
            exit 1
          fi
          echo "✓ Code formatting OK"
          echo ""
          
          echo "→ Cloning nostrdb with submodules..."
          if [ ! -d "nostrdb" ]; then
            git clone https://github.com/damus-io/nostrdb.git --depth 1
            cd nostrdb
            git submodule update --init --recursive --depth 1
            cd ..
          fi
          echo "✓ nostrdb cloned"
          echo ""
          
          echo "→ Building project..."
          # Use Zig's bundled musl libc for consistent builds
          export ZIG_LOCAL_CACHE_DIR="$(pwd)/.zig-cache"
          export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache-$$"
          
          # Try with x86_64-linux-musl for Linux CI environment
          if ! ${zigPkg}/bin/zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl; then
            echo "✗ Build failed!"
            exit 1
          fi
          echo "✓ Build successful"
          echo ""
          
          echo "→ Running tests..."
          if ! ${zigPkg}/bin/zig build test -Dtarget=x86_64-linux-musl; then
            echo "✗ Tests failed!"
            exit 1
          fi
          echo "✓ All tests passed"
          echo ""
          
          echo "→ Building megalith CLI..."
          if ! ${zigPkg}/bin/zig build megalith -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl; then
            echo "✗ Megalith build failed!"
            exit 1
          fi
          echo "✓ Megalith CLI built successfully"
          echo ""
          
          # Check for common issues
          echo "→ Running additional checks..."
          
          # Check for TODO/FIXME comments (informational only)
          TODO_COUNT=$(grep -r "TODO\|FIXME" --include="*.zig" . 2>/dev/null | wc -l || echo "0")
          if [ "$TODO_COUNT" -gt 0 ]; then
            echo "ℹ Found $TODO_COUNT TODO/FIXME comments"
          fi
          
          # Check for unreachable code patterns
          UNREACHABLE_COUNT=$(grep -r "unreachable" --include="*.zig" . 2>/dev/null | wc -l || echo "0")
          if [ "$UNREACHABLE_COUNT" -gt 0 ]; then
            echo "ℹ Found $UNREACHABLE_COUNT uses of 'unreachable'"
          fi
          
          echo ""
          echo "=== ✓ CI passed successfully! ==="
        '';

      in
      {
        # Development shell with all dependencies
        devShells.default = pkgs.mkShell {
          buildInputs = devDeps ++ [
            ciScript
          ];
          
          shellHook = ''
            echo "NostrDB Zig development environment"
            echo "Available commands:"
            echo "  zig build         - Build the project"
            echo "  zig build test    - Run tests"
            echo "  zig build megalith - Build the megalith CLI"
            echo "  zig fmt .         - Format code"
            echo "  ci               - Run full CI suite"
            echo ""
            echo "Zig version: $(${zigPkg}/bin/zig version)"
          '';
        };
        
        # CI output that can be run with `nix run .#ci`
        packages.ci = ciScript;
        
        # Default package (builds the project)
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "nostrdb-zig";
          version = "0.0.1";
          
          src = ./.;
          
          nativeBuildInputs = devDeps;
          
          buildPhase = ''
            # Clone nostrdb locally for the build
            git clone https://github.com/damus-io/nostrdb.git --depth 1
            cd nostrdb
            git submodule update --init --recursive --depth 1
            cd ..
            
            # Build with release optimization
            zig build -Doptimize=ReleaseSafe --prefix $out
            
            # Also build megalith CLI  
            zig build megalith -Doptimize=ReleaseSafe --prefix $out
          '';
          
          installPhase = ''
            # The zig build system handles installation with --prefix
            echo "Installation completed by zig build"
          '';
        };
        
        # Convenience app for running CI
        apps.ci = {
          type = "app";
          program = "${ciScript}/bin/ci";
        };
      });
}