{ pkgs, lib, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "mn2hmtl";
  version = "canon";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./mn2html.rs
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  passthru.shell = pkgs.mkShell {
    name = "${pname}-shell";
    nativeBuildInputs = [
      pkgs.buildPackages.cargo
      pkgs.buildPackages.rustc
    ];
  };
}
