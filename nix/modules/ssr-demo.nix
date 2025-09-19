{ config, lib, pkgs, ... }:
let
  cfg = config.services.nostrdb-ssr;
in {
  options.services.nostrdb-ssr = {
    enable = lib.mkEnableOption "Run the NostrDB SSR demo service";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Package providing the ssr-demo binary. Set to inputs.nostrdb-zig.packages.<system>.ssr-demo.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nostrdb";
      description = "User account to run the service as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nostrdb";
      description = "Group for the service.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nostrdb-ssr";
      description = "Directory holding the LMDB data used by the SSR server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port to bind.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra command-line arguments to pass to ssr-demo.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users."${cfg.user}" = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups."${cfg.group}" = {};

    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.nostrdb-ssr.package must be set to the ssr-demo package (e.g., inputs.nostrdb-zig.packages.${pkgs.system}.ssr-demo).";
      }
    ];

    systemd.services.nostrdb-ssr = {
      description = "NostrDB SSR Demo Server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "nostrdb-ssr";
        WorkingDirectory = cfg.dataDir;
        ExecStart = ''${cfg.package}/bin/ssr-demo --db-path ${cfg.dataDir} --port ${builtins.toString cfg.port} ${lib.concatStringsSep " " cfg.extraArgs}'';
        Restart = "on-failure";
        RestartSec = 2;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        LockPersonality = true;
      };
      preStart = ''
        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
      '';
    };
  };
}
