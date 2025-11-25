{
  depot,
  lib,
  pkgs,
  ...
}:

depot.nix.readTree.drvTargets rec {
  # Provide a Terraform wrapper with the right provider installed.
  terraform = pkgs.terraform.withPlugins (p: [
    p.digitalocean_digitalocean
  ]);

  validate = depot.tools.checks.validateTerraform {
    inherit terraform;
    name = "dns";
    src = lib.cleanSource ./.;
  };
}
