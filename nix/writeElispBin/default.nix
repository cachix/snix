{ depot, pkgs, ... }:

{ name, src, deps ? (_: [ ]), emacs ? pkgs.emacs-nox }:

let
  inherit (pkgs) emacsPackages emacsPackagesFor;
  inherit (builtins) isString toFile;

  finalEmacs = (emacsPackagesFor emacs).emacsWithPackages deps;

  srcFile =
    if isString src
    then toFile "${name}.el" src
    else src;

in
depot.nix.writeScriptBin name ''
  #!/bin/sh
  ${finalEmacs}/bin/emacs --batch --no-site-file --script ${srcFile} $@
''
