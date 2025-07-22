{ depot, ... }:

depot.snix.mkCargoBuild {
  name = "nix-compat-derive-tests";
  buildPhase = ''
    cargo test -p nix-compat-derive-tests 2>&1 | tee -a $out
  '';
}
