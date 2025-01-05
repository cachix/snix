# Shell derivation to invoke //nix/lazy-deps with the dependencies
# that should be lazily made available in depot.
{ depot, ... }:

depot.nix.lazy-deps {
  age-keygen.attr = "third_party.nixpkgs.age";
  age.attr = "third_party.nixpkgs.age";
  depotfmt.attr = "tools.depotfmt";
  git-r.attr = "tools.git-r";
  git-review.attr = "third_party.nixpkgs.git-review";
  gerrit-update.attr = "tools.gerrit-update";
  gerrit.attr = "tools.gerrit-cli";
  josh-filter.attr = "third_party.nixpkgs.josh";
  mg.attr = "tools.magrathea";
  nint.attr = "nix.nint";
  niv.attr = "third_party.nixpkgs.niv";
  rebuild-system.attr = "ops.nixos.rebuild-system";
  rink.attr = "third_party.nixpkgs.rink";

  tf-buildkite = {
    attr = "ops.buildkite.terraform";
    cmd = "terraform";
  };

  tf-keycloak = {
    attr = "ops.keycloak.terraform";
    cmd = "terraform";
  };
}
