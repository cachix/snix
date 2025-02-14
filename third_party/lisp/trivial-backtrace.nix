# Imported from http://common-lisp.net/project/trivial-backtrace/trivial-backtrace.git
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.trivial-backtrace;
in depot.nix.buildLisp.library {
  name = "trivial-backtrace";

  srcs = map (f: src + ("/dev/" + f)) [
    "packages.lisp"
    "utilities.lisp"
    "backtrace.lisp"
    "map-backtrace.lisp"
    "fallback.lisp"
  ];
}
