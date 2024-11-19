{ config
, lib
, pkgs
, depot
, ...
}:
let
  cfg = config.services.nar-bridge;

  package = depot.tvix.nar-bridge.override (old: {
    features = old.features or [ "default" ] ++ [ "xp-store-composition-cli" ];
    runTests = true;
  });

  storeCompositionFormat = pkgs.formats.toml { };

  storeCompositionFile = storeCompositionFormat.generate "store-composition.toml" cfg.settings;

  args = [
    "--listen-address"
    "sd-listen"
    "--experimental-store-composition"
    storeCompositionFile
  ];
in
{
  options = {
    services.nar-bridge = {
      enable = lib.mkEnableOption "nar-bridge service";

      settings = lib.mkOption {
        type = storeCompositionFormat.type;
        default = { };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nar-bridge = {
      isSystemUser = true;
      group = "nar-bridge";
    };

    users.groups.nar-bridge = { };

    systemd.sockets.nar-bridge = {
      description = "nar-bridge socket";
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        LimitNOFILE = 65535;
        ListenStream = "/run/nar-bridge.sock";
        SocketMode = "0666";
        SocketUser = "root";
      };
    };

    systemd.services.nar-bridge = {
      description = "NAR Bridge";
      requires = [ "nar-bridge.socket" ];
      after = [ "nar-bridge.socket" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${package}/bin/nar-bridge ${lib.escapeShellArgs args}";

        Restart = "always";
        RestartSec = "10";

        User = "nar-bridge";
        Group = "nar-bridge";
        StateDirectory = "nar-bridge";
      };
    };
  };
}
