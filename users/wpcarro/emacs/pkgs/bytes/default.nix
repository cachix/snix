{ pkgs, depot, ... }:

let
  bytes = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "bytes";
        version = "1.0.0";
        src = ./bytes.el;
        packageRequires =
          (with depot.users.wpcarro.emacs.pkgs; [
            tuple
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [ bytes ]);
in
bytes.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
