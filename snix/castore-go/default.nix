{ depot, pkgs, ... }:

let
  regenerate = pkgs.writeShellScript "regenerate" ''
    (cd $(git rev-parse --show-toplevel)/snix/castore-go && rm *.pb.go && cp ${depot.snix.castore.protos.go-bindings}/*.pb.go . && chmod +w *.pb.go)
  '';
in
(pkgs.buildGoModule {
  name = "castore-go";
  src = depot.third_party.gitignoreSource ./.;
  vendorHash = "sha256:03wwzk7irlb05y0zjfmpp5c2dxhcpnmfc169g05sn6d3ni07aly8";
  meta.ci.extraSteps = {
    check = {
      label = ":water_buffalo: ensure generated protobuf files match";
      needsOutput = true;
      command = pkgs.writeShellScript "pb-go-check" ''
        ${regenerate}
        if [[ -n "$(git status --porcelain -unormal)" ]]; then
            echo "-----------------------------"
            echo ".pb.go files need to be updated, mg run //snix/castore-go/regenerate"
            echo "-----------------------------"
            git status -unormal
            exit 1
        fi
      '';
      alwaysRun = true;
    };
  };
  passthru.regenerate = regenerate;
})
