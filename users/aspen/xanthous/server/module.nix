{ config, lib, pkgs, depot, ... }:

let
  cfg = config.services.xanthous-server;
in
{
  options = with lib; {
    services.xanthous-server = {
      enable = mkEnableOption "xanthous server";

      port = mkOption {
        type = types.int;
        default = 2222;
        description = "Port to listen to for SSH connections";
      };

      metricsPort = mkOption {
        type = types.int;
        default = 9000;
        description = "Port to listen to for prometheus metrics";
      };

      image = mkOption {
        type = types.package;
        default = depot.users.aspen.xanthous.server.docker;
        description = "OCI image file to run";
      };

      ed25519SecretKeyFile = mkOption {
        type = with types; uniq str;
        description = "Path to the ed25519 secret key for the server";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers."xanthous-server" = {
      autoStart = true;
      image = "${cfg.image.imageName}:${cfg.image.imageTag}";
      imageFile = cfg.image;
      ports = [
        "${toString cfg.port}:22"
        "${toString cfg.metricsPort}:9000"
      ];
      environment.SECRET_KEY_FILE = "/secret-key";
      volumes = [ "/etc/secrets/xanthous-server-secret-key:/secret-key" ];
    };
  };
}
