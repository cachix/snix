{ pkgs, depot, ... }:

let
  fs = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "fs";
        version = "1.0.0";
        src = ./fs.el;
        packageRequires =
          (with emacsPackages; [
            dash
            f
            s
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    fs
  ]);
in
fs.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
