{ pkgs, depot, ... }:

let
  bag = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "bag";
        version = "1.0.0";
        src = ./bag.el;
        packageRequires =
          (with depot.users.wpcarro.emacs.pkgs; [
            al
            list
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [ bag ]);
in
bag.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
})
