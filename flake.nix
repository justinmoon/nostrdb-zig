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
        linuxExtraDeps = if pkgs.stdenv.hostPlatform.isLinux then with pkgs; [
          gcc
          glibc
          glibc.dev
          linuxHeaders
        ] else [];

        darwinExtraDeps = if pkgs.stdenv.hostPlatform.isDarwin then [ pkgs.clang ] else [];

        devDeps = with pkgs; [
          zigPkg
          pkg-config
          # C dependencies for nostrdb
          lmdb
          secp256k1
          # Build tools
          gnumake
          cmake
          # Git for fetching submodules
          git
          cargo
          rustc
        ] ++ linuxExtraDeps ++ darwinExtraDeps;
        
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
          
          # Set up C environment for Zig
          export CC="${pkgs.stdenv.cc}/bin/cc"
          export AR="${pkgs.stdenv.cc.bintools.bintools}/bin/ar"
          
          # On Linux, we need to help Zig find the libc
          # Note: This section is only evaluated at runtime on Linux, not during Nix evaluation
          if [[ "$(uname)" == "Linux" ]]; then
            export ZIG_LIBC_TXT="$(mktemp)"
            cat > "$ZIG_LIBC_TXT" <<'LIBC_EOF'
          include_dir=${pkgs.glibc.dev}/include
          sys_include_dir=${pkgs.glibc.dev}/include
          static_include_dir=${pkgs.glibc.dev}/include
          crt_dir=${pkgs.glibc}/lib
          static_crt_dir=${pkgs.glibc}/lib
          msvc_lib_dir=
          kernel32_lib_dir=
          gcc_dir=${pkgs.stdenv.cc.cc}/lib/gcc/${pkgs.stdenv.cc.targetPlatform.config}/${pkgs.stdenv.cc.cc.version}
          dynamic_linker=${pkgs.stdenv.cc.bintools.dynamicLinker}
          LIBC_EOF
            export ZIG_LIBC="$ZIG_LIBC_TXT"
            export GLIBC_INCLUDE_DIR=${pkgs.glibc.dev}/include
            export LINUX_HEADERS_DIR=${pkgs.linuxHeaders}/include
            export GLIBC_LIB_DIR=${pkgs.glibc}/lib
            export C_INCLUDE_PATH="${pkgs.glibc.dev}/include:${pkgs.linuxHeaders}/include"
            export LIBRARY_PATH="${pkgs.glibc}/lib"
          fi
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
          echo "→ Ensuring OpenMLS workspace checkouts..."
          mkdir -p checkouts/openmls
          if [ ! -d "checkouts/openmls/repo" ]; then
            git clone --depth 1 --branch openmls-v0.7.0 https://github.com/openmls/openmls.git checkouts/openmls/repo
          fi
          echo "✓ OpenMLS crates prepared"
          echo ""
          
          echo "→ Preparing Rust toolchain..."
          export CARGO_HOME="''${TMPDIR:-/tmp}/cargo-home"
          mkdir -p "$CARGO_HOME"
          export PATH="${pkgs.cargo}/bin:${pkgs.rustc}/bin:$PATH"
          export RUST_BACKTRACE=1
          ${pkgs.cargo}/bin/cargo --version
          ${pkgs.rustc}/bin/rustc --version
          echo ""

          echo "→ Building Zig targets..."
          ${zigPkg}/bin/zig build
          echo ""

          echo "→ Running Zig unit tests..."
          ${zigPkg}/bin/zig build test
          echo ""

          echo "→ Running OpenMLS FFI integration tests..."
          ${zigPkg}/bin/zig build openmls-ffi-test
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
          
          nativeBuildInputs = devDeps ++ [ pkgs.cacert ];
          
          # Skip configure phase since we're using Zig
          configurePhase = ''
            echo "Skipping configure phase (Zig project)"
          '';
          
          buildPhase = ''
            # Set up SSL certificates for git
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export GIT_SSL_CAINFO="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            
            # Set up Zig cache directory 
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            
            # Clone nostrdb locally for the build
            ${pkgs.git}/bin/git clone https://github.com/damus-io/nostrdb.git --depth 1
            cd nostrdb
            ${pkgs.git}/bin/git submodule update --init --recursive --depth 1
            cd ..
            
            # Set up Zig paths
            export PATH="${zigPkg}/bin:$PATH"
            
            # Build with release optimization
            ${zigPkg}/bin/zig build -Doptimize=ReleaseSafe --prefix $out
            
            # Also build megalith CLI  
            ${zigPkg}/bin/zig build megalith -Doptimize=ReleaseSafe --prefix $out
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