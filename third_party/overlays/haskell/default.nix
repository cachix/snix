# Defines an overlay for overriding Haskell packages, for example to
# avoid breakage currently present in nixpkgs or to modify package
# versions.

{ lib, ... }:

self: super: # overlay parameters for the nixpkgs overlay

let
  haskellLib = self.haskell.lib.compose;
in
{
  haskellPackages = super.haskellPackages.override {
    overrides = hsSelf: hsSuper: {
      punycode = haskellLib.appendPatch
        (self.fetchpatch {
          name = "punycode-mtl-2.3.patch";
          url = "https://github.com/litherum/punycode/pull/5/commits/41e55c8b7cef14563e6d04a7190dbabff5a77886.patch";
          sha256 = "03kgmy4z36jv16ffp5jrig2gr8ydc8cl1iscc7difisaq88mxvqc";
        })
        hsSuper.punycode;

      # Build with deprecated ansi-wl-pprint is broken now, use HEAD which switched to
      # prettyprinter
      tmp-postgres = haskellLib.overrideSrc
        {
          version = "unstable-2023-08-08";
          src = self.fetchFromGitHub {
            owner = "jfischoff";
            repo = "tmp-postgres";
            rev = "7f2467a6d6d5f6db7eed59919a6773fe006cf22b";
            sha256 = "0l1gdx5s8ximgawd3yzfy47pv5pgwqmjqp8hx5rbrq68vr04wkbl";
          };
        }
        (hsSuper.tmp-postgres.override {
          ansi-wl-pprint = hsSelf.prettyprinter;
        });

      pa-prelude = hsSelf.callPackage ./extra-pkgs/pa-prelude.nix { };
      pa-error-tree = hsSelf.callPackage ./extra-pkgs/pa-error-tree-0.1.0.0.nix { };
      pa-field-parser = hsSelf.callPackage ./extra-pkgs/pa-field-parser.nix { };
      pa-label = hsSelf.callPackage ./extra-pkgs/pa-label.nix { };
      pa-pretty = hsSelf.callPackage ./extra-pkgs/pa-pretty-0.1.1.0.nix { };
      pa-json = hsSelf.callPackage ./extra-pkgs/pa-json.nix { };
      pa-run-command = hsSelf.callPackage ./extra-pkgs/pa-run-command-0.1.0.0.nix { };
    };
  };

  haskell = lib.recursiveUpdate super.haskell {
    packages.ghc8107 = super.haskell.packages.ghc8107.override {
      overrides = hsSelf: hsSuper: {
        # TODO(sterni): TODO(grfn): patch xanthous to work with random-fu 0.3.*,
        # so we can use GHC 9.0.2 and benefit from upstream binary cache.
        random-fu = hsSelf.callPackage ./extra-pkgs/random-fu-0.2.nix { };
        rvar = hsSelf.callPackage ./extra-pkgs/rvar-0.2.nix { };

        # TODO(grfn): port to brick 1.4 (EventM gains an additional type argument in 1.0)
        brick = hsSelf.callPackage ./extra-pkgs/brick-0.73.nix { };
      };
    };
  };
}
