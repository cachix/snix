{ config, depot, lib, ... }:

let
  cfg = config.services.depot.gerrit-webhook-to-irccat;
  description = "receive gerrit webhooks and forward to irccat";
in

{
  options.services.depot.gerrit-webhook-to-irccat = {
    enable = lib.mkEnableOption description;

    irccatUrl = lib.mkOption {
      type = lib.types.str;
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.gerrit-webhook-to-irccat = {
      serviceConfig = {
        ExecStart = "${depot.ops.gerrit-webhook-to-irccat}/bin/gerrit-webhook-to-irccat" +
          " -irccat-url ${cfg.irccatUrl}";
        Restart = "always";
        RestartSec = 5;
        User = "gerrit-webhook-to-irccat";
        DynamicUser = true;
        ProtectHome = true;
        ProtectSystem = true;
        MemoryDenyWriteExecute = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
    systemd.sockets.gerrit-webhook-to-irccat = {
      wantedBy = [ "sockets.target" ];
      socketConfig.ListenStream = cfg.listenAddress;
    };
  };
}
