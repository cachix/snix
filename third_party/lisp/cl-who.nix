{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-who;
in depot.nix.buildLisp.library {
  name = "cl-who";

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "specials.lisp"
    "util.lisp"
    "who.lisp"
  ];
}
