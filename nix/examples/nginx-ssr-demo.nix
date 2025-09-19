{ config, lib, pkgs, ... }:
let
  # Upstream SSR service port; should match services.nostrdb-ssr.port
  upstreamPort = 8080;
  serverName = "mega.justinmoon.com"; # change to your domain
in {
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    virtualHosts."${serverName}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString upstreamPort}";
        proxyWebsockets = true;
      };
    };
  };
}

