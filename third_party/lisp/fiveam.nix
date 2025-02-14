# FiveAM is a Common Lisp testing framework.
#
# Imported from https://github.com/sionescu/fiveam.git

{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.fiveam;
in depot.nix.buildLisp.library {
  name = "fiveam";

  deps = with depot.third_party.lisp; [
    alexandria
    asdf-flv
    trivial-backtrace
  ];

  srcs = map (f: src + ("/src/" + f)) [
    "package.lisp"
    "utils.lisp"
    "check.lisp"
    "fixture.lisp"
    "classes.lisp"
    "random.lisp"
    "test.lisp"
    "explain.lisp"
    "suite.lisp"
    "run.lisp"
  ];
}
