# This file is shell.nix in the snix josh workspace,
# *and* used to provide the //snix:shell attribute in a full depot checkout.
# Hence, it may not use depot as a toplevel argument.

{
  # This falls back to the snix josh workspace-provided nixpkgs checkout.
  # In the case of depot, it's always set explicitly.
  pkgs ? (import ./nixpkgs {
    depotOverlays = false;
    depot.third_party.sources = import ./sources { };
  })
, withIntegration ? false
, ...
}:

pkgs.mkShell {
  name = "snix-rust-dev-env";
  packages = [
    pkgs.buf
    pkgs.cargo
    pkgs.cargo-machete
    pkgs.cargo-expand
    pkgs.cargo-flamegraph
    pkgs.clippy
    pkgs.d2
    pkgs.evans
    pkgs.fuse
    pkgs.go
    pkgs.grpcurl
    pkgs.hyperfine
    pkgs.mdbook
    pkgs.mdbook-admonish
    pkgs.mdbook-d2
    pkgs.mdbook-plantuml
    pkgs.pkg-config
    pkgs.rust-analyzer
    pkgs.rustc
    pkgs.rustfmt
    pkgs.plantuml
    pkgs.protobuf
  ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.runc
  ] ++ pkgs.lib.optionals withIntegration [
    pkgs.cbtemulator
    pkgs.google-cloud-bigtable-tool
  ];

  # Set SNIX_BENCH_NIX_PATH to a somewhat pinned nixpkgs path.
  # This is for invoking `cargo bench` imperatively on the developer machine.
  # For snix benchmarking across longer periods of time (by CI), we probably
  # should also benchmark with a more static nixpkgs checkout, so nixpkgs
  # refactorings are not observed as eval perf changes.
  shellHook = ''
    export SNIX_BUILD_SANDBOX_SHELL=${if pkgs.stdenv.isLinux then pkgs.busybox-sandbox-shell + "/bin/busybox" else "/bin/sh"}
    export SNIX_BENCH_NIX_PATH=nixpkgs=${pkgs.path}
  '';
}
