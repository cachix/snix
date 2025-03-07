{ pkgs, depot, ... }:

let
  math = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "math";
        version = "1.0.0";
        src = ./math.el;
        packageRequires =
          (with emacsPackages; [
            dash
          ]) ++
          (with depot.users.wpcarro.emacs.pkgs; [
            maybe
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    math
  ]);
in
math.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
