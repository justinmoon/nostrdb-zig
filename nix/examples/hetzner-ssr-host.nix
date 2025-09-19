{ inputs, pkgs, lib, ... }:
{
  imports = [
    inputs.nostrdb-zig.nixosModules.ssr-demo
    inputs.nostrdb-zig.nix.examples.caddy-ssr-demo
  ];

  services.nostrdb-ssr = {
    enable = true;
    package = inputs.nostrdb-zig.packages.${pkgs.system}.ssr-demo;
    dataDir = "/var/lib/nostrdb-ssr";
    port = 8080;
  };

  # Optional: open port if firewall is enabled
  networking.firewall.allowedTCPPorts = [ 8080 80 443 ];
}

