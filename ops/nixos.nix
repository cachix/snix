# Helper functions for instantiating depot-compatible NixOS machines.
{
  depot,
  lib,
  pkgs,
  ...
}@args:

let
  inherit (lib) findFirst;
in
rec {
  # This provides our standard set of arguments to all NixOS modules.
  baseModule =
    { ... }:
    {
      nix.nixPath =
        let
          # Due to nixpkgsBisectPath, pkgs.path is not always in the nix store
          nixpkgsStorePath =
            if lib.hasPrefix builtins.storeDir (toString pkgs.path) then
              builtins.storePath pkgs.path # nixpkgs is already in the store
            else
              pkgs.path; # we need to dump nixpkgs to the store either way
        in
        [
          ("nixos=" + nixpkgsStorePath)
          ("nixpkgs=" + nixpkgsStorePath)
        ];
    };

  nixosFor =
    configuration:
    (depot.third_party.nixos {
      configuration =
        { ... }:
        {
          imports = [
            baseModule
            configuration
          ];
        };

      specialArgs = {
        inherit (args) depot;
      };
    });

  findSystem =
    hostname:
    (findFirst (
      system: system.config.networking.hostName == hostname
    ) (throw "${hostname} is not a known NixOS host") (map nixosFor depot.ops.machines.all-systems));

  # Systems that should be built in CI
  archivistEC2System = (nixosFor depot.ops.machines.archivist-ec2).system;
  gerrit01System = (nixosFor depot.ops.machines.gerrit01).system;
  public01System = (nixosFor depot.ops.machines.public01).system;
  build01System = (nixosFor depot.ops.machines.build01).system;
  meta01System = (nixosFor depot.ops.machines.meta01).system;
  nixosSnixCacheSystem = (nixosFor depot.ops.machines.snix-cache).system;

  meta.ci.targets = [
    "archivistEC2System"
    "gerrit01System"
    "public01System"
    "build01System"
    "meta01System"
  ];
}
