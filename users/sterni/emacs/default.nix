{ depot, pkgs, lib, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) is64bit;

  # Wrap chktex(1) with the flags we want because the chktex flycheck checker
  # ignores tex-chktex-extra-flags and has no other way to set flags. I did
  # not want to mess around with chktexrc because that seems to involve copying
  # around a lot of rules (that would need to be updated?).
  #
  # Warning 8 is about correct dash length. This is really annoying because it'll
  # light up everywhere if you use typographically correct dashes in German text.
  chktexLessWarnings = pkgs.writeShellScript "chktex-less-warnings" ''
    exec chktex -n8 "$@"
  '';

  emacs = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).withPackages (epkgs: [
    epkgs.bqn-mode
    #epkgs.elpaPackages.ada-mode
    epkgs.elpaPackages.rainbow-mode
    epkgs.elpaPackages.undo-tree
    epkgs.elpaPackages.which-key
    epkgs.melpaPackages.adoc-mode
    epkgs.melpaPackages.cmake-mode
    epkgs.melpaPackages.deft
    epkgs.melpaPackages.direnv
    epkgs.melpaPackages.dockerfile-mode
    epkgs.melpaPackages.editorconfig
    epkgs.melpaPackages.elfeed
    epkgs.melpaPackages.evil
    epkgs.melpaPackages.evil-collection
    epkgs.melpaPackages.flycheck
    epkgs.melpaPackages.haskell-mode
    epkgs.melpaPackages.hl-todo
    epkgs.melpaPackages.jq-mode
    epkgs.melpaPackages.lsp-haskell
    epkgs.melpaPackages.lsp-mode
    epkgs.melpaPackages.lsp-ui
    epkgs.melpaPackages.magit
    epkgs.melpaPackages.markdown-mode
    epkgs.melpaPackages.meson-mode
    epkgs.melpaPackages.nix-mode
    epkgs.melpaPackages.org-clock-csv
    epkgs.melpaPackages.paredit
    epkgs.melpaPackages.rainbow-delimiters
    epkgs.melpaPackages.sly
    epkgs.melpaPackages.yaml-mode
    epkgs.rust-mode
    epkgs.tvlPackages.tvl
    epkgs.urweb-mode
  ] ++ lib.optionals is64bit [
    epkgs.melpaPackages.languagetool
  ]);

  configDirectory = pkgs.symlinkJoin {
    name = "emacs.d";
    paths = [
      ./.
      (pkgs.writeTextFile {
        name = "injected-emacs.d";
        destination = "/nix-inject.el";
        text =
          # Java doesn't seem to be available for non 64bit platforms in nixpkgs
          # CBQN doesn't seem to support i686 at least
          lib.optionalString is64bit ''
            ;; bqn-mode
            (setq bqn-interpreter-path "${pkgs.cbqn}/bin/BQN")

            ;; languagetool
            (setq languagetool-java-bin "${pkgs.jre}/bin/java"
                  languagetool-console-command "${pkgs.languagetool}/share/languagetool-commandline.jar"
                  languagetool-server-command "${pkgs.languagetool}/share/languagetool-server.jar")
          '' + ''

            ;; use bash instead of fish from SHELL for some things, as it plays
            ;; nicer with TERM=dumb, as I don't need/want vterm anyways.
            ;; We want it to source /etc/profile for some extra setup that
            ;; kicks in if TERM=dumb, meaning we can't use dash/sh mode.
            (setq shell-file-name "${pkgs.bash}/bin/bash"
                  explicit-bash-args '("-l"))

            ;; chktex wrapper that disables warnings I don't want
            (setq flycheck-tex-chktex-executable "${chktexLessWarnings}")
            (setq tex-chktex-program "${chktexLessWarnings}")

            (provide 'nix-inject)
        '';
      })
    ];
    postBuild = ''
      rm "$out/default.nix"
    '';
  };
in

# sadly we can't give an init-file via the command line
(pkgs.writeShellScriptBin "emacs" ''
  exec ${emacs}/bin/emacs          \
    --no-init-file                 \
    --directory ${configDirectory} \
    --eval "(require 'init)"       \
    "$@"
'').overrideAttrs (super: {
  buildCommand = ''
    ${super.buildCommand}

    ln -s "${emacs}/bin/emacsclient" "$out/bin/emacsclient"
  '';
})
