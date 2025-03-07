{ pkgs, depot, ... }:

let
  vector = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "vector";
        version = "1.0.0";
        src = ./vector.el;
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [ vector ]);
in
vector.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
