{ pkgs, depot, ... }:

let
  string = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "string";
        version = "1.0.0";
        src = ./string.el;
        packageRequires = [
          emacsPackages.dash
          emacsPackages.s
        ];
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    string
  ]);
in
string.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
