{
  depot,
  lib,
  pkgs,
  ...
}:

depot.nix.readTree.drvTargets rec {
  terraform = pkgs.terraform.withPlugins (p: [
    p.buildkite_buildkite
  ]);

  validate = depot.tools.checks.validateTerraform {
    inherit terraform;
    name = "buildkite";
    src = lib.cleanSource ./.;
    env.BUILDKITE_API_TOKEN = "ci-dummy";
  };
}
