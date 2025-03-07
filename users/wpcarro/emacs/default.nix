# My Emacs distribution, which is supporting the following platforms:
# - Linux
# - Darwin
#
# USAGE:
#   $ nix-build -A users.wpcarro.emacs.osx -o /Applications/BillsEmacs.app
{ depot, pkgs, lib, ... }:

# TODO(wpcarro): See if it's possible to expose emacsclient on PATH, so that I
# don't need to depend on wpcarros-emacs and emacs in my NixOS configurations.
let
  inherit (depot.third_party.nixpkgs) emacsPackagesFor emacs;
  inherit (depot.users) wpcarro;
  inherit (lib) mapAttrsToList;
  inherit (lib.strings) concatStringsSep makeBinPath;
  inherit (pkgs) runCommand writeShellScriptBin;

  emacsBinPath = makeBinPath (
    wpcarro.common.shell-utils ++
    # Rust dependencies
    (with pkgs; [
      cargo
      rust-analyzer
      rustc
      rustfmt
    ]) ++
    # Misc dependencies
    (with pkgs; [
      ispell
      nix
      rust-analyzer
      rustc
      rustfmt
      xorg.xset
    ] ++
    (if pkgs.stdenv.isLinux then [
      scrot
    ] else [ ]))
  );

  emacsWithPackages = (emacsPackagesFor emacs).emacsWithPackages;

  wpcarrosEmacs = emacsWithPackages (epkgs:
    (with wpcarro.emacs.pkgs; [
      al
      bookmark
      cycle
      list
      macros
      maybe
      passage
      set
      string
      struct
      symbol
      theme
      tuple
      vterm-mgt
      zle
    ]) ++

    (with epkgs.tvlPackages; [
      tvl
    ]) ++

    (with epkgs.elpaPackages; [
      exwm
    ]) ++

    (with epkgs.melpaPackages; [
      alert
      all-the-icons
      all-the-icons-ivy
      avy
      base16-theme
      cider
      clojure-mode
      company
      counsel
      counsel-projectile
      csharp-mode
      dap-mode
      dash
      deadgrep
      deferred
      diminish
      direnv
      dockerfile-mode
      # TODO(wpcarro): broken since channel bump cl/10204
      # doom-themes
      elisp-slime-nav
      elixir-mode
      elm-mode
      emojify
      engine-mode
      evil
      evil-collection
      evil-commentary
      evil-surround
      f
      fish-mode
      flycheck
      flymake-shellcheck
      general
      go-mode
      haskell-mode
      helpful
      ivy
      ivy-clipmenu
      ivy-prescient
      key-chord
      lispyville
      lsp-ui
      magit
      magit-popup
      markdown-mode
      nix-mode
      notmuch
      org-bullets
      package-lint
      paradox
      parsec
      pcre2el
      prettier-js
      projectile
      py-yapf
      racket-mode
      rainbow-delimiters
      reason-mode
      refine
      request
      restclient
      rjsx-mode
      rust-mode
      sly
      suggest
      telephone-line
      terraform-mode
      tide
      ts
      tuareg
      vterm
      web-mode
      which-key
      yaml-mode
      yasnippet
    ]) ++

    [
      epkgs.eglot # from elpa devel
    ]);

  loadPath = concatStringsSep ":" [
    ./.emacs.d/wpc
    # TODO(wpcarro): Explain why the trailing ":" is needed.
    "${wpcarrosEmacs.deps}/share/emacs/site-lisp:"
  ];

  # Transform an attrset into "export k=v" statements.
  makeEnvVars = env: concatStringsSep "\n"
    (mapAttrsToList (k: v: "export ${k}=\"${v}\"") env);

  withEmacsPath = { emacsBin, env ? { }, load ? [ ] }:
    writeShellScriptBin "wpcarros-emacs" ''
      export XMODIFIERS=emacs
      export PATH="${emacsBinPath}:$PATH"
      export EMACSLOADPATH="${loadPath}"
      ${makeEnvVars env}
      exec ${emacsBin} \
        --debug-init \
        --no-init-file \
        --no-site-file \
        --no-site-lisp \
        --load ${./.emacs.d/init.el} \
        ${concatStringsSep "\n  " (map (el: "--load ${el} \\") load)}
        "$@"
    '';

  # I can't figure out how to augment LSEnvironment.PATH such that it inherits
  # the default $PATH and adds the things that I need as well, so let's
  # hardcode the desired outcome in the meantime.
  osxDefaultPath = builtins.concatStringsSep ":" [
    "/Users/bill/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
    "/opt/X11/bin"
  ];

  infoPlist = pkgs.writeText "Info.plist" (pkgs.lib.generators.toPlist { } {
    LSEnvironment = {
      PATH = "${emacsBinPath}:${osxDefaultPath}";
    };
    CFBundleExecutable = "BillsEmacs";
    CFBundleDisplayName = "BillsEmacs";
    CFBundleIconFile = "AppIcon";
    CFBundleIconName = "AppIcon";
  });

  versionPlist = pkgs.writeText "version.plist" (pkgs.lib.generators.toPlist { } {
    ProjectName = "OSXPlatformSupport";
  });
in
{
  # TODO(wpcarro): Support this with base.overrideAttrs or something similar.
  nixos = { load ? [ ] }: withEmacsPath {
    inherit load;
    emacsBin = "${wpcarrosEmacs}/bin/emacs";
  };

  # To install GUI:
  # $ nix-build -A users.wpcarro.emacs.osx -o /Applications/BillsEmacs.app
  osx = pkgs.stdenv.mkDerivation {
    pname = "bills-emacs";
    version = "0.0.1";
    src = ./.;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      APP="$out"
      mkdir -p "$APP/Contents/MacOS"
      mkdir -p "$APP/Contents/Resources"
      cp ${infoPlist}      "$APP/Contents/Info.plist"
      cp ${versionPlist}   "$APP/Contents/version.plist"
      cp ${./AppIcon.icns} "$APP/Contents/Resources/AppIcon.icns"
      echo "APPL????"  > "$APP/Contents/PkgInfo"
      cat << EOF > "$APP/Contents/MacOS/BillsEmacs"
      #!${pkgs.stdenvNoCC.shell}
      export EMACSLOADPATH="${loadPath}"
      exec ${wpcarrosEmacs}/bin/emacs \
        --debug-init \
        --no-init-file \
        --no-site-file \
        --no-site-lisp \
        --load ${./.emacs.d/init.el}
      EOF
      chmod +x "$APP/Contents/MacOS/BillsEmacs"
      runHook postInstall
    '';
    meta.platforms = [ "aarch64-darwin" ];
  };

  # Script that asserts my Emacs can initialize without warnings or errors.
  check = runCommand "check-emacs" { } ''
    # Even though Buildkite defines this, I'd still like still be able to test
    # this locally without depending on my ability to remember to set CI=true.
    export CI=true
    export PATH="${emacsBinPath}:$PATH"
    export EMACSLOADPATH="${loadPath}"
    ${wpcarrosEmacs}/bin/emacs \
      --no-site-file \
      --no-site-lisp \
      --no-init-file \
      --script ${./ci.el} \
      ${./.emacs.d/init.el} && \
    touch $out
  '';

  # TODO(wpcarro): commented out because of doom-themes breakage; cl/10204
  # meta.ci.targets = [ "check" ];
}
