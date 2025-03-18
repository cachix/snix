{ depot, pkgs, ... }:

let
  # assumes `name` is configured appropriately in your .ssh/config
  deployScript = name: sys: pkgs.writeShellScriptBin "deploy-${name}" ''
    set -eo pipefail
    nix-copy-closure --to ${name} --gzip --use-substitutes ${sys}
    ssh ${name} nix-env --profile /nix/var/nix/profiles/system --set ${sys}
    ssh ${name} ${sys}/bin/switch-to-configuration switch
  '';

in
depot.nix.readTree.drvTargets rec {
  archivistEc2System = (depot.ops.nixos.nixosFor ({ ... }: {
    imports = [
      ./archivist-ec2/configuration.nix
    ];
  })).config.system.build.toplevel;

  deploy-archivist-ec2 = (deployScript "archivist-ec2" archivistEc2System);

  nixosTvixCacheSystem = (depot.ops.nixos.nixosFor ({ ... }: {
    imports = [
      ./nixos-tvix-cache/configuration.nix
    ];
  })).config.system.build.toplevel;

  deploy-nixos-tvix-cache = (deployScript "root@nixos.tvix.store" nixosTvixCacheSystem);

  deps = (depot.nix.lazy-deps {
    deploy-archivist-ec2.attr = "users.flokli.nixos.deploy-archivist-ec2";
    aws.attr = "third_party.nixpkgs.awscli";
  });

  shell = pkgs.mkShell {
    name = "flokli-nixos-shell";
    packages = [ deps ];
  };
}
