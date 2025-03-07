# This overlay is used to make TVL-specific modifications in the
# nixpkgs tree, where required.
{ lib, depot, localSystem, ... }:

self: super:
depot.nix.readTree.drvTargets {
  nix_2_3 = (super.nix_2_3.override {
    # flaky tests, long painful build, see https://github.com/NixOS/nixpkgs/pull/266443
    withAWS = false;
  }).overrideAttrs (_: {
    # use TVL maintenance branch for 2.3, which has more fixes than upstream
    CXXFLAGS = "--std=c++20 -g";
    dontStrip = true;
    src = self.fetchFromGitHub {
      owner = "tvlfyi";
      repo = "nix";
      rev = "d516e2826128c09588535b67aa27fd3e24288b5f";
      sha256 = "04yxxhhq4542gakfh2kylnhq9fagfzv63shrq0qvf8rajflwxr22";
    };
  });

  nix = self.nix_2_3 // {
    # avoid duplicate pipeline step
    meta = self.nix_2_3.meta or { } // {
      ci = self.nix_2_3.meta.ci or { } // {
        skip = true;
      };
    };
  };

  nix_latest_stable = super.nix.override ({
    # flaky tests, long painful build, see https://github.com/NixOS/nixpkgs/pull/266443
    withAWS = false;
  });

  # No longer builds with Nix 2.3 after
  # https://github.com/nixos/nixpkgs/commit/5f9d2d95721cdf20ace744f2db75ad70a7aedd3a
  nixos-option = super.nixos-option.override {
    nix = self.nix_latest_stable;
  };

  home-manager = super.home-manager.overrideAttrs (_: {
    src = depot.third_party.sources.home-manager;
    version = "git-"
      + builtins.substring 0 7 depot.third_party.sources.home-manager.rev;
  });

  niri = super.niri.overrideAttrs (_: {
    doCheck = false;
  });

  # Add our Emacs packages to the fixpoint
  emacsPackagesFor = emacs: (
    (super.emacsPackagesFor emacs).overrideScope (eself: esuper: {
      tvlPackages = depot.tools.emacs-pkgs // depot.third_party.emacs;

      # Use the notmuch from nixpkgs instead of from the Emacs
      # overlay, to avoid versions being out of sync.
      notmuch = super.notmuch.emacs;

      # Build EXWM with the depot sources instead.
      depotExwm = eself.callPackage depot.third_party.exwm.override { };

      # Workaround for magit checking the git version at load time
      magit = esuper.magit.overrideAttrs (_: {
        propagatedNativeBuildInputs = [
          self.git
        ];
      });

      # Pin xelb to a newer one until the new maintainers do a release.
      xelb = eself.trivialBuild {
        pname = "xelb";
        version = "0.19-dev"; # invented version, last actual release was 0.18

        src = self.fetchFromGitHub {
          owner = "emacs-exwm";
          repo = "xelb";
          rev = "86089eba2de6c818bfa2fac075cb7ad876262798";
          sha256 = "1mmlrd2zpcwiv8gh10y7lrpflnbmsycdascrxjr3bfcwa8yx7901";
        };
      };

      # Override telega sources to specific commits, and check its exact tdlib version requirement.
      checkedTelega =
        let
          pinned = esuper.telega.overrideAttrs (_: {
            version = "0.8.999"; # unstable
            src = self.fetchFromGitHub {
              owner = "zevlg";
              repo = "telega.el";
              rev = "431c8d8c6388b8e77548d68da70a1eb44f562a98";
              sha256 = "0q6ljzlfzkf59rd86qd47yilny17k9gq4plv20lisk4i3213fzdh";
            };
          });

          requiredTdlibFile = self.runCommandNoCC "required-tdlib" { } ''
            ${self.ripgrep}/bin/rg -o -r '$1' 'tdlib_version=v(.*)$' ${pinned.src}/etc/Dockerfile > $out
          '';

          requiredTdlib = self.lib.strings.trim (builtins.readFile "${requiredTdlibFile}");
        in
        assert requiredTdlib == self.tdlib.version; pinned; # ping tazjin if this fails
    })
  );

  # dottime support for notmuch
  notmuch = super.notmuch.overrideAttrs (old: {
    passthru = old.passthru // {
      patches = old.patches ++ [ ./patches/notmuch-dottime.patch ];
    };
  });

  # Avoid builds of mkShell derivations in CI.
  mkShell = super.lib.makeOverridable (args: (super.mkShell args).overrideAttrs (_: {
    passthru = {
      meta.ci.skip = true;
    };
  }));

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

  # https://gcc.gnu.org/gcc-14/porting_to.html#warnings-as-errors
  thttpd = super.thttpd.overrideAttrs (oldAttrs: {
    NIX_CFLAGS_COMPILE = oldAttrs.NIX_CFLAGS_COMPILE or [ ] ++ [
      "-Wno-error=implicit-int"
      "-Wno-error=implicit-function-declaration"
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

  # Dependency isn't supported by Python 3.12
  html5validator = super.html5validator.override {
    python3 = self.python311;
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
        }) else super.fuse;

  # somebody renamed 'utillinux' upstream, but didn't rename all use-cases,
  # leading to some packages being broken.
  #
  # temporarily restore the old name to make things work again.
  utillinux = self.util-linux;

  # harmonia >2.0 broke compatibility with Nix 2.3; revert back for now
  harmonia = self.rustPlatform.buildRustPackage rec {
    pname = "harmonia";
    version = "1.0.2";
    doCheck = false;
    cargoHash = "sha256-gW/OljEngDQddIovtgwghu7uHLFVZHvWIijPgbOOkDc=";
    meta.mainProgram = "harmonia";

    src = self.fetchFromGitHub {
      owner = "nix-community";
      repo = "harmonia";
      rev = "refs/tags/harmonia-v${version}";
      hash = "sha256-72nDVSvUfZsLa2HbyricOpA0Eb8gxs/VST25b6DNBpM=";
    };

    nativeBuildInputs = with self; [
      pkg-config
      nixVersions.nix_2_24
    ];

    buildInputs = with self; [
      boost
      libsodium
      openssl
      nlohmann_json
      nixVersions.nix_2_24
    ];
  };
}
