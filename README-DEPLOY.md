NixOS Deployment — SSR Demo

This repository provides a Nix flake for packaging and deploying the `ssr-demo` server as a NixOS service. The service renders a simple Nostr timeline from an LMDB directory created by NostrDB.

Quick Start (NixOS)
- Add this repo as a flake input and import the module.
- Enable the service and set the data directory and port.
- Optionally proxy with nginx and issue TLS certificates via ACME.

Example flake.nix (on your server)
```
{
  description = "host config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nostrdb-zig.url = "github:damus-io/nostrdb-zig"; # or your fork/branch
  };

  outputs = { self, nixpkgs, nostrdb-zig }:
    let system = "x86_64-linux"; in {
      nixosConfigurations.mega = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hardware-configuration.nix
          nostrdb-zig.nixosModules.ssr-demo
          ({ config, pkgs, ... }: {
            services.nostrdb-ssr = {
              enable = true;
              package = nostrdb-zig.packages.${system}.ssr-demo;
              dataDir = "/var/lib/nostrdb-ssr";
              port = 8080;
              extraArgs = [ ];
            };

            # Optional nginx reverse proxy with ACME
            # imports = [ nostrdb-zig.nix.examples.nginx-ssr-demo ];
          })
        ];
      };
    };
}
```

Seed the database
- Copy or mount an LMDB directory to `services.nostrdb-ssr.dataDir` (default: `/var/lib/nostrdb-ssr`).
- Or generate sample data as described in `ssr/main.zig` help and copy the result.

Activate
- Build and switch: `sudo nixos-rebuild switch --flake .#mega`
- Service runs as `nostrdb` user, listening on `0.0.0.0:${port}`.

Run locally with Nix
- `nix run .#ssr-demo -- --db-path ./demo-db --port 8080`

nginx example
- See `nix/examples/nginx-ssr-demo.nix` for a simple vhost that proxies to `127.0.0.1:${port}` with ACME TLS.

Troubleshooting
- Ensure the LMDB directory exists and is owned by the `services.nostrdb-ssr.user` (default: `nostrdb`).
- Check logs: `journalctl -u nostrdb-ssr -f`.
- Build in a dev shell: `nix develop` then `zig build ssr-demo`.

