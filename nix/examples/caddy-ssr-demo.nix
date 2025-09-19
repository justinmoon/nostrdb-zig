{ config, lib, pkgs, ... }:
let
  upstreamPort = 8080; # must match services.nostrdb-ssr.port
  serverName = "mega.justinmoon.com"; # change if needed
in {
  services.caddy = {
    enable = true;
    virtualHosts."${serverName}" = {
      extraConfig = ''
        encode zstd gzip
        header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        @websockets {
          header Connection *Upgrade*
          header Upgrade websocket
        }
        reverse_proxy @websockets 127.0.0.1:${toString upstreamPort}
        reverse_proxy 127.0.0.1:${toString upstreamPort}
      '';
    };
  };
}

