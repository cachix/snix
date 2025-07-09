# Nix helpers for projects under //snix
{ pkgs, lib, depot, here, ... }:

let
  # Load the crate2nix crate tree.
  crates = pkgs.callPackage ./Cargo.nix {
    defaultCrateOverrides = here.utils.defaultCrateOverridesForPkgs pkgs;
  };

  # Cargo dependencies to be used with nixpkgs rustPlatform functions.
  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
    # Extract the hashes from `crates` / Cargo.nix, we already get them from cargo2nix.
    # This returns an attribute set containing "${crateName}-${version}" as key,
    # and the outputHash as value.
    outputHashes = builtins.listToAttrs
      (map
        (k:
          (lib.nameValuePair "${crates.internal.crates.${k}.crateName}-${crates.internal.crates.${k}.version}" crates.internal.crates.${k}.src.outputHash)
        ) [
        "wu-manber"
      ]);
  };

  # The cleaned sources.
  src = depot.third_party.gitignoreSource ./.;

  # Target containing *all* snix proto files.
  # Useful for workspace-wide cargo invocations (doc, clippy)
  protos = pkgs.symlinkJoin {
    name = "snix-all-protos";
    paths = [
      here.build.protos.protos
      here.castore.protos.protos
      here.store.protos.protos
    ];
  };

in
{
  inherit crates protos;

  # Provide the snix logo in both .webp and .png format.
  logo = pkgs.runCommand "logo"
    {
      nativeBuildInputs = [ pkgs.imagemagick ];
    } ''
    mkdir -p $out
    cp ${./logo.webp} $out/logo.webp
    convert $out/logo.webp $out/logo.png
  '';

  # Provide a shell for the combined dependencies of all snix Rust
  # projects. Note that as this is manually maintained it may be
  # lacking something, but it is required for some people's workflows.
  #
  # This shell can be entered with e.g. `mg shell //snix:shell`.
  # This is a separate file, so it can be used individually in the snix josh
  # workspace too.
  shell = (import ./shell.nix { inherit pkgs; });

  # Shell, but with tools necessary to run the integration tests
  shell-integration = (import ./shell.nix { inherit pkgs; withIntegration = true; });

  # Build the Rust documentation for publishing on snix.dev/rustdoc.
  rust-docs = pkgs.stdenv.mkDerivation {
    inherit cargoDeps src;
    name = "snix-rust-docs";
    PROTO_ROOT = protos;
    # This path is resolved at build time in the Nix build environment
    SNIX_BUILD_SANDBOX_SHELL = if pkgs.stdenv.isLinux then pkgs.busybox-sandbox-shell + "/bin/busybox" else "/bin/sh";

    nativeBuildInputs = with pkgs; [
      cargo
      pkg-config
      protobuf
      rustc
      rustPlatform.cargoSetupHook
    ];

    buildInputs = [
      pkgs.fuse
    ] ++ lib.optional pkgs.stdenv.isDarwin pkgs.libiconv;

    buildPhase = ''
      RUSTDOCFLAGS="-D rustdoc::broken-intra-doc-links" cargo doc --document-private-items
      mv target/doc $out
    '';
  };

  # Run cargo clippy. We run it with -Dwarnings, so warnings cause a nonzero
  # exit code.
  clippy = pkgs.stdenv.mkDerivation {
    inherit cargoDeps src;
    name = "snix-clippy";
    PROTO_ROOT = protos;
    # This path is resolved at build time in the Nix build environment
    SNIX_BUILD_SANDBOX_SHELL = if pkgs.stdenv.isLinux then pkgs.busybox-sandbox-shell + "/bin/busybox" else "/bin/sh";

    buildInputs = [
      pkgs.fuse
    ];
    nativeBuildInputs = with pkgs; [
      cargo
      clippy
      pkg-config
      protobuf
      rustc
      rustPlatform.cargoSetupHook
    ];

    buildPhase = "cargo clippy --tests --all-features --benches --examples -- -Dwarnings | tee $out";
  };

  crate2nix-check =
    let
      crate2nix-check = here.utils.mkCrate2nixCheck ./Cargo.nix;
    in
    crate2nix-check.command.overrideAttrs {
      meta.ci.extraSteps = {
        inherit crate2nix-check;
      };
    };

  meta.ci.targets = [
    "clippy"
    "shell"
    "shell-integration"
    "rust-docs"
    "crate2nix-check"
  ];

  utils = import ./utils.nix { inherit pkgs lib depot; };
}
