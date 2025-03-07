{ pkgs, depot, ... }:

let
  struct = pkgs.callPackage
    ({ emacsPackages }:
      emacsPackages.trivialBuild {
        pname = "struct";
        version = "1.0.0";
        src = ./struct.el;
        packageRequires = [ ];
      })
    { };

  emacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    struct
  ]);
in
struct.overrideAttrs (_old: {
  doCheck = true;
  checkPhase = ''
    ${emacs}/bin/emacs -batch \
      -l ert -l ${./tests.el} -f ert-run-tests-batch-and-exit
  '';
  passthru.meta.ci.extraSteps.github = depot.tools.releases.filteredGitPush {
    filter = ":/users/wpcarro/emacs/pkgs/struct";
    remote = "git@github.com:wpcarro/struct.el.git";
    ref = "refs/heads/canon";
  };
})
