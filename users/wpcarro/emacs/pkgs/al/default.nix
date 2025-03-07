{ pkgs, depot, ... }:

let
  al = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "al";
        version = "1.0.0";
        src = ./al.el;
        packageRequires =
          (with emacsPackages; [
            dash
          ]) ++
          (with depot.users.wpcarro.emacs.pkgs; [
            list
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [ al ]);
in
al.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
