{ pkgs, depot, ... }:

let
  cycle = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "cycle";
        version = "1.0.0";
        src = ./cycle.el;
        packageRequires =
          (with emacsPackages; [
            dash
          ]) ++
          (with depot.users.wpcarro.emacs.pkgs; [
            struct
          ]);
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    epkgs.dash
    cycle
  ]);
in
cycle.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
  passthru.meta.ci.extraSteps.github = depot.tools.releases.filteredGitPush {
    filter = ":/users/wpcarro/emacs/pkgs/cycle";
    remote = "git@github.com:wpcarro/cycle.el.git";
    ref = "refs/heads/canon";
  };
})
