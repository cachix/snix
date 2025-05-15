{ pkgs, lib, ... }:

pkgs.buildGoModule {
  name = "gerrit-webhook-to-irccat";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./main.go
      ./go.mod
      ./go.sum
    ];
  };
  vendorHash = "sha256-x5ldt3KWL6ri5UqbKFXN717R4JVTIFZyn5DsgGi/RY4=";
}
