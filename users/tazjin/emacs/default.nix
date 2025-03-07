# This file builds an Emacs pre-configured with the packages I need
# and my personal Emacs configuration.
{ depot, lib, pkgs, ... }:

pkgs.makeOverridable
  ({ emacs ? pkgs.emacs-pgtk }:
  let
    emacsPackages = (pkgs.emacsPackagesFor emacs);
    emacsWithPackages = emacsPackages.emacsWithPackages;

    # $PATH for binaries that need to be available to Emacs
    emacsBinPath = lib.makeBinPath [
      emacsPackages.checkedTelega
      pkgs.libwebp # for dwebp, required by telega
    ];

    identity = x: x;

    # tree-sitter grammars for various ts-modes
    customTreesitGrammars = emacs.pkgs.treesit-grammars.with-grammars (g: with g; [
      tree-sitter-bash
      tree-sitter-c
      tree-sitter-cmake
      tree-sitter-cpp
      tree-sitter-css
      tree-sitter-dockerfile
      tree-sitter-go
      tree-sitter-gomod
      tree-sitter-hcl
      tree-sitter-html
      tree-sitter-java
      tree-sitter-json
      tree-sitter-latex
      tree-sitter-make
      tree-sitter-nix
      tree-sitter-python
      tree-sitter-rust
      tree-sitter-sql
      tree-sitter-toml
      tree-sitter-typescript
      tree-sitter-yaml
    ]);

    tazjinsEmacs = pkgfun: (emacsWithPackages (epkgs: pkgfun (with epkgs; [
      ace-link
      ace-window
      avy
      bazel
      browse-kill-ring
      cargo
      clojure-mode
      company
      company-prescient
      consult
      deft
      direnv
      elixir-mode
      elm-mode
      erlang
      go-mode
      google-c-style
      gruber-darker-theme
      haskell-mode
      ht
      hydra
      idle-highlight-mode
      inspector
      jq-mode
      kotlin-mode
      kubernetes
      magit
      markdown-toc
      multiple-cursors
      nginx-mode
      nix-mode
      notmuch
      paredit
      password-store
      pinentry
      prescient
      protobuf-mode
      rainbow-delimiters
      rainbow-mode
      request
      restclient
      rust-mode
      sly
      string-edit-at-point
      terraform-mode
      undo-tree
      uuidgen
      vertico
      vertico-prescient
      vterm
      web-mode
      websocket
      which-key
      xelb
      yasnippet
      zetteldeft
      zoxide

      # Wonky stuff
      checkedTelega
      customTreesitGrammars # TODO(tazjin): how is this *supposed* to work?!

      # Custom depot packages (either ours, or overridden ones)
      tvlPackages.dottime
      tvlPackages.niri
      tvlPackages.nix-util
      tvlPackages.passively
      tvlPackages.rcirc
      tvlPackages.term-switcher
      tvlPackages.treecrumbs
      tvlPackages.tvl

      # Dynamic/native modules
      depot.users.tazjin.gio-list-apps
    ])));
  in
  lib.fix
    (self: l: f: (pkgs.writeShellScriptBin "tazjins-emacs" ''
      export PATH="${emacsBinPath}:$PATH"
      exec ${tazjinsEmacs f}/bin/emacs \
        --debug-init \
        --no-site-file \
        --no-site-lisp \
        --no-init-file \
        --directory ${./config} ${if l != null then "--directory ${l}" else ""} \
        --eval "(add-to-list 'treesit-extra-load-path \"${customTreesitGrammars}/lib\")" \
        --eval "(require 'init)" $@
    '').overrideAttrs
      (_: {
        passthru = {
          # Expose original Emacs used for my configuration.
          inherit emacs;

          # Expose the pure emacs with all packages.
          inherit emacsPackages;
          emacsWithPackages = tazjinsEmacs f;

          # Call overrideEmacs with a function (pkgs -> pkgs) to modify the
          # packages that should be included in this Emacs distribution.
          overrideEmacs = f': self l f';

          # Call withLocalConfig with the path to a *folder* containing a
          # `local.el` which provides local system configuration.
          withLocalConfig = confDir: self confDir f;
        };
      }))
    null
    identity
  )
{ }
