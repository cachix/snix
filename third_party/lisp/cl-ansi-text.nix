# Enables ANSI colors for printing.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-ansi-text;
in depot.nix.buildLisp.library {
  name = "cl-ansi-text";
  deps = with depot.third_party.lisp; [
    alexandria
    cl-colors2
  ];

  srcs = map (f: src + ("/src/" + f)) [
    "cl-ansi-text.lisp"
    "define-colors.lisp"
  ];
}
