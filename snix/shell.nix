{ pkgs, ... }:

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
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.runc
    pkgs.cbtemulator
    pkgs.google-cloud-bigtable-tool
  ];

  # Set SNIX_BENCH_NIX_PATH to a somewhat pinned nixpkgs path.
  # This is for invoking `cargo bench` imperatively on the developer machine.
  # For snix benchmarking across longer periods of time (by CI), we probably
  # should also benchmark with a more static nixpkgs checkout, so nixpkgs
  # refactorings are not observed as eval perf changes.
  shellHook = ''
    export SNIX_BUILD_SANDBOX_SHELL=${
      if pkgs.stdenv.isLinux then pkgs.busybox-sandbox-shell + "/bin/busybox" else "/bin/sh"
    }
    export SNIX_BENCH_NIX_PATH=nixpkgs=${toString pkgs.path}

    snixShellHook() {
      # Somewhat brute force check. Lix uses .this-is-lix in repo root.
      if [[ ! -d ./snix || ! -e ./.git ]]; then
        echo "Dev shell not started from within the Snix repo, skipping repo setup" >&2
        return
      fi

      local gitcommondir
      # Install the Gerrit commit-msg hook.
      # (git common dir is the main .git, including for worktrees)
      if gitcommondir=$(git rev-parse --git-common-dir 2>/dev/null) && [[ ! -f "$gitcommondir/hooks/commit-msg" ]]; then
        echo 'Installing Gerrit commit-msg hook (adds Change-Id to commit messages)' >&2
        mkdir -p "$gitcommondir/hooks"
        curl -s -Lo "$gitcommondir/hooks/commit-msg" https://cl.snix.dev/tools/hooks/commit-msg
        chmod u+x "$gitcommondir/hooks/commit-msg"
      fi
    }
    snixShellHook
  '';
}
