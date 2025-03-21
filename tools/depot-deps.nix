# Shell derivation to invoke //nix/lazy-deps with the dependencies
# that should be lazily made available in depot.
{ depot, ... }:

depot.nix.lazy-deps {
  age-keygen.attr = "third_party.nixpkgs.age";
  age.attr = "third_party.nixpkgs.age";
  depotfmt.attr = "tools.depotfmt";
  git-review.attr = "third_party.nixpkgs.git-review";
  gerrit-update.attr = "tools.gerrit-update";
  gerrit.attr = "tools.gerrit-cli";
  josh-filter.attr = "third_party.nixpkgs.josh";
  mg.attr = "tools.magrathea";
  nint.attr = "nix.nint";
  niv.attr = "third_party.nixpkgs.niv";
  nixpkgs-fmt.attr = "third_party.nixpkgs.nixpkgs-fmt";
  rink.attr = "third_party.nixpkgs.rink";

  tf-buildkite = {
    attr = "ops.buildkite.terraform";
    cmd = "terraform";
  };

  tf-dns = {
    attr = "ops.dns.terraform";
    cmd = "terraform";
  };

  tf-hcloud = {
    attr = "ops.hcloud.terraform";
    cmd = "terraform";
  };

  tf-hetzner-s3 = {
    attr = "ops.hetzner-s3.terraform";
    cmd = "terraform";
  };

  tf-keycloak = {
    attr = "ops.keycloak.terraform";
    cmd = "terraform";
  };
}
