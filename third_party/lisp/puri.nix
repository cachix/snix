# Portable URI library
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.puri;
in depot.nix.buildLisp.library {
  name = "puri";
  srcs = [
    (src + "/src.lisp")
  ];
}
