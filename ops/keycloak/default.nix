{
  depot,
  lib,
  pkgs,
  ...
}:

depot.nix.readTree.drvTargets rec {
  # Provide a Terraform wrapper with the right provider installed.
  terraform = pkgs.terraform.withPlugins (p: [
    p.keycloak_keycloak
  ]);

  validate = depot.tools.checks.validateTerraform {
    inherit terraform;
    name = "keycloak";
    src = lib.cleanSource ./.;
  };
}
