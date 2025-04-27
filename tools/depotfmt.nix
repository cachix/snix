# Builds treefmt for depot, with a hardcoded configuration that
# includes the right paths to formatters.
{ pkgs, ... }:

let
  config = pkgs.writeText "depot-treefmt-config" ''
    [formatter.go]
    command = "${pkgs.go}/bin/gofmt"
    options = [ "-w" ]
    includes = ["*.go"]

    [formatter.nix]
    command = "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt"
    includes = [ "*.nix" ]
    excludes = [
      "snix/eval/src/tests/nix_tests/*",
    ]

    [formatter.rust]
    command = "${pkgs.rustfmt}/bin/rustfmt"
    includes = [ "*.rs" ]

    [formatter.editorconfig]
    command = "${pkgs.editorconfig-checker}/bin/editorconfig-checker"
    includes = [
      "*.c",
      "*.conf",
      "*.css",
      "*.exp",
      "*.go",
      "*.h",
      "*.hcl",
      "*.html",
      "*.java",
      "*.jq",
      "*.js",
      "*.json",
      "*.md",
      "*.nix",
      "*.proto",
      "*.py",
      "*.rs",
      "*.scm",
      "*.scss",
      "*.sh",
      "*.tf",
      "*.toml",
      "*.txt",
      "*.xml",
      "*.yaml",
      "*.yml"
    ]
    excludes = [
      "snix/eval/src/tests/nix_tests/*",

      # contains "References: ", which has trailing whitespace
      # FUTUREWORK: move into separate fixture and read from here
      "snix/nix-compat/src/narinfo/mod.rs"
    ]
  '';

  # helper tool for formatting the depot interactively
  depotfmt = pkgs.writeShellScriptBin "depotfmt" ''
    exec ${pkgs.treefmt}/bin/treefmt ''${@} \
      --on-unmatched=debug \
      --config-file=${config} \
      --tree-root $(${pkgs.git}/bin/git rev-parse --show-toplevel)
  '';

  # wrapper script for running formatting checks in CI
  check = pkgs.writeShellScript "depotfmt-check" ''
    ${pkgs.treefmt}/bin/treefmt \
      --no-cache \
      --on-unmatched=debug \
      --fail-on-change \
      --config-file=${config} \
      --tree-root=.
  '';
in
depotfmt.overrideAttrs (_: {
  passthru = {
    inherit config check;
    meta.ci.extraSteps.check = {
      label = "depot formatting check";
      command = check;
      alwaysRun = true;
    };
  };
})
