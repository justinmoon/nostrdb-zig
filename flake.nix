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
          cmake
          # Git for fetching submodules
          git
        ] ++ lib.optionals stdenv.isLinux [
          gcc
        ] ++ lib.optionals stdenv.isDarwin [
          clang
        ];
        
        # small wrapper to run scripts/ci.sh with needed tools in PATH
        ciWrapper = pkgs.writeShellScriptBin "ci" ''
          set -euo pipefail
          export PATH="${zigPkg}/bin:${pkgs.git}/bin:${pkgs.pkg-config}/bin:${pkgs.stdenv.cc}/bin:${pkgs.stdenv.cc.bintools.bintools}/bin:$PATH"
          export CC="${pkgs.stdenv.cc}/bin/cc"
          export AR="${pkgs.stdenv.cc.bintools.bintools}/bin/ar"
          exec ${pkgs.bash}/bin/bash ${./scripts/ci.sh}
        '';

      in
      {
        # Development shell with all dependencies
        devShells.default = pkgs.mkShell {
          buildInputs = devDeps;
        };
        
        # CI app that can be run with `nix run .#ci`
        packages.ci = ciWrapper;
        
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
            
            # Ensure nostrdb submodule is available for the build
            ${pkgs.git}/bin/git submodule update --init --recursive
            
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
        apps.ci = { type = "app"; program = "${ciWrapper}/bin/ci"; };
      });
}
