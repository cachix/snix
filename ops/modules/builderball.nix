# Configuration for builderball, the Nix cache proxy for substituting between
# builders.
#
# This is in experimental state, not yet supporting any dynamic private builders.
{ depot, config, lib, ... }:

let
  cfg = config.services.depot.builderball;
  description = "Nix cache proxy for distribution between builders";
  hostname = config.networing.hostName;
in
{
  options.services.depot.builderball = {
    enable = lib.mkEnableOption description;

    caches = lib.mkOption {
      type = with lib.types; listOf str;
      description = "Public addresses of caches to use";

      default = [
        "nevsky.cache.tvl.fyi"
      ];
    };

    port = lib.mkOption {
      type = lib.types.int;
      description = "port on which to listen locally";
      default = 26862; # bounc
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.builderball =
      let
        caches = lib.concatStringsSep " " (map (c: "-cache https://${c}") cfg.caches);
      in
      {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        serviceConfig = {
          ExecStart = "${depot.ops.builderball}/bin/builderball ${caches} -port ${toString cfg.port} -debug";
          DynamicUser = true;
          Restart = "always";
        };
      };
  };
}
