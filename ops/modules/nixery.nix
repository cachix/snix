# NixOS module to run Nixery, currently with local-storage as the
# backend for storing/serving image layers.
{ depot, config, lib, pkgs, ... }:

let
  cfg = config.services.depot.nixery;
  description = "Nixery - container images on-demand";
  nixpkgsSrc = depot.third_party.sources.nixpkgs;
  storagePath = "/var/lib/nixery/${nixpkgsSrc.rev}";
in
{
  options.services.depot.nixery = {
    enable = lib.mkEnableOption description;

    port = lib.mkOption {
      type = lib.types.int;
      default = 45243; # "image"
      description = "Port on which Nixery should listen";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixery = {
      inherit description;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "nixery";
        Restart = "always";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${storagePath}";
        ExecStart = "${depot.tools.nixery.nixery}/bin/server";
      };

      environment = {
        PORT = toString cfg.port;
        NIXERY_PKGS_PATH = nixpkgsSrc.outPath;
        NIXERY_STORAGE_BACKEND = "filesystem";
        NIX_TIMEOUT = "60"; # seconds
        STORAGE_PATH = storagePath;
      };
    };
  };
}
