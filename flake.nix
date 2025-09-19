{
  description = "NostrDB Zig - A Zig wrapper for the NostrDB library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nostrdb = {
      url = "git+https://github.com/damus-io/nostrdb?submodules=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig, nostrdb }:
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
          cmake
          # Git for fetching submodules
          git
        ] ++ lib.optionals stdenv.isLinux [
          gcc
        ] ++ lib.optionals stdenv.isDarwin [
          clang
        ];
        
        # CI script kept outside flake for readability
        ciScript = pkgs.writeShellScriptBin "ci" (builtins.readFile ./scripts/ci.sh);

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
            # Nix injects many CFLAGS/LDFLAGS that Zig's bundled Clang may not recognize.
            # Unset them to avoid build failures (e.g., -fmacro-prefix-map errors).
            unset NIX_CFLAGS_COMPILE || true
            unset NIX_LDFLAGS || true
            unset NIX_CFLAGS_COMPILE_FOR_TARGET || true
            unset NIX_LDFLAGS_FOR_TARGET || true
            if [[ "${pkgs.stdenv.hostPlatform.system}" == *-darwin ]]; then
              if command -v xcrun >/dev/null 2>&1; then
                export SDKROOT=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
                if [[ -n "$SDKROOT" && -d "$SDKROOT" ]]; then
                  export APPLE_SDK_FRAMEWORKS="$SDKROOT/System/Library/Frameworks"
                  export APPLE_SDK_SYSTEM_INCLUDE="$SDKROOT/usr/include"
                  export APPLE_SDK_LIBRARY="$SDKROOT/usr/lib"
                  echo "Configured Apple SDK paths for Zig:"
                  echo "  APPLE_SDK_FRAMEWORKS=$APPLE_SDK_FRAMEWORKS"
                else
                  echo "Warning: Could not determine SDKROOT via xcrun. Ensure Xcode/CLT installed."
                fi
              else
                echo "Warning: xcrun not found. Install Xcode Command Line Tools: xcode-select --install"
              fi
              if [[ ! -f nostrdb/src/nostrdb.c ]]; then
                echo "Note: nostrdb submodule missing. Run: git submodule update --init --recursive"
              fi
            fi
          '';
        };
        
        # Packages
        packages = {
          ci = ciScript;
        } // pkgs.lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          ssr-demo = pkgs.stdenv.mkDerivation {
          pname = "nostrdb-ssr-demo";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = devDeps ++ [ pkgs.cacert ];
          configurePhase = ''
            echo "Skipping configure phase (Zig project)"
          '';
          buildPhase = ''
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export GIT_SSL_CAINFO="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            # Ensure nostrdb sources are available in the build tree
            if [ ! -f "nostrdb/src/nostrdb.c" ]; then
              echo "Copying nostrdb sources from flake input"
              rm -rf nostrdb
              cp -R ${nostrdb} nostrdb
            fi
            test -f "nostrdb/src/nostrdb.c"
            export PATH="${zigPkg}/bin:$PATH"
            ${zigPkg}/bin/zig build ssr-demo -Doptimize=ReleaseSafe --prefix $out
          '';
          installPhase = ''
            echo "Installation completed by zig build (ssr-demo)"
          '';
          meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };
        
        # Apps
        apps = {
          ci = { type = "app"; program = "${ciScript}/bin/ci"; };
        } // pkgs.lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          "ssr-demo" = { type = "app"; program = "${self.packages.${system}.ssr-demo}/bin/ssr-demo"; };
        };
      }) // {
        # Export example modules/utilities that aren't system-specific
        nix = {
          examples = {
            nginx-ssr-demo = import ./nix/examples/nginx-ssr-demo.nix;
          };
        };
        nixosModules = {
          ssr-demo = import ./nix/modules/ssr-demo.nix;
        };
      };
}
