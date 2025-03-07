{ pkgs, depot, ... }:

let
  set = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "set";
        version = "1.0.0";
        src = ./set.el;
        packageRequires =
          (with emacsPackages; [
            dash
            ht
          ]) ++
          (with depot.users.wpcarro.emacs.pkgs; [
            struct
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    epkgs.dash
    set
  ]);
in
set.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
