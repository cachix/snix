# This overlay is used to make TVL-specific modifications in the
# nixpkgs tree, where required.
{ lib
, depot
, localSystem
, ...
}:

self: super:
depot.nix.readTree.drvTargets {
  # Avoid builds of mkShell derivations in CI.
  mkShell = super.lib.makeOverridable (
    args:
    (super.mkShell args).overrideAttrs (_: {
      passthru = {
        meta.ci.skip = true;
      };
    })
  );

  crate2nix = super.crate2nix.overrideAttrs (old: {
    patches = old.patches or [ ] ++ [
      # TODO(Kranzes): Remove in next release.
      ./patches/crate2nix-0001-Fix-Use-mkDerivation-with-src-instead-of-runCommand.patch
      # https://github.com/nix-community/crate2nix/pull/301
      ./patches/crate2nix-tests-debug.patch
    ];
  });

  evans = super.evans.overrideAttrs (old: {
    patches = old.patches or [ ] ++ [
      # add support for unix domain sockets
      # https://github.com/ktr0731/evans/pull/680
      ./patches/evans-add-support-for-unix-domain-sockets.patch
    ];
  });

  # https://github.com/NixOS/nixpkgs/pull/329415/files
  grpc-health-check = super.rustPlatform.buildRustPackage {
    pname = "grpc-health-check";
    version = "unstable-2022-08-19";

    src = super.fetchFromGitHub {
      owner = "paypizza";
      repo = "grpc-health-check";
      rev = "f61bb5e10beadc5ed53144cc540d66e19fc510bd";
      hash = "sha256-nKut9c1HHIacdRcmvlXe0GrtkgCWN6sxJ4ImO0CIDdo=";
    };

    cargoHash = "sha256-lz+815iE+oXBQ3PfqBO0QBpZY6x1SNR7OU7BjkRszzI=";

    nativeBuildInputs = [ super.protobuf ];
    # tests fail
    doCheck = false;
  };

  # macFUSE bump containing fix for https://github.com/osxfuse/osxfuse/issues/974
  # https://github.com/NixOS/nixpkgs/pull/320197
  fuse =
    if super.stdenv.isDarwin then
      super.fuse.overrideAttrs
        (old: rec {
          version = "4.8.0";
          src = super.fetchurl {
            url = "https://github.com/osxfuse/osxfuse/releases/download/macfuse-${version}/macfuse-${version}.dmg";
            hash = "sha256-ucTzO2qdN4QkowMVvC3+4pjEVjbwMsB0xFk+bvQxwtQ=";
          };
        })
    else
      super.fuse;
}
