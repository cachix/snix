# This file configures the primary build pipeline used for the
# top-level list of depot targets.
{ depot, pkgs, externalArgs, ... }:

let
  pipeline = depot.nix.buildkite.mkPipeline {
    headBranch = "refs/heads/canon";
    drvTargets = depot.ci.targets;

    parentTargetMap =
      if (externalArgs ? parentTargetMap)
      then builtins.fromJSON (builtins.readFile externalArgs.parentTargetMap)
      else { };

    postBuildSteps = [
      # After successful builds, create a gcroot for builds on canon.
      #
      # This anchors *most* of the depot, in practice it's unimportant
      # if there is a build race and we get +-1 of the targets.
      #
      # Unfortunately this requires a third evaluation of the graph, but
      # since it happens after :duck: it should not affect the timing of
      # status reporting back to Gerrit.
      {
        label = ":anchor:";
        branches = "refs/heads/canon";
        command = ''
          rm /nix/var/nix/gcroots/buildkite/canon
          nix-build -A ci.gcroot --out-link /nix/var/nix/gcroots/buildkite/canon
        '';

        # Ensure that anchoring happens on build01, so that a possibly deployed
        # binary cache there has the store paths. Unanchored machines may
        # garbage collect live paths.
        agents.hostname = "build01";
      }
    ];
  };

  drvmap = depot.nix.buildkite.mkDrvmap depot.ci.targets;
in
pkgs.runCommand "depot-pipeline" { } ''
  mkdir $out
  cp -r ${pipeline}/* $out
  cp ${drvmap} $out/drvmap.json
''
