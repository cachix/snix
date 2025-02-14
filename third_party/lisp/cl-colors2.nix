# TODO(sterni): package (switch to?) cl-colors-ng
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-colors2;
in depot.nix.buildLisp.library {
  name = "cl-colors2";
  deps = with depot.third_party.lisp; [
    alexandria
    cl-ppcre
    parse-number
    {
      sbcl = depot.nix.buildLisp.bundled "uiop";
      default = depot.nix.buildLisp.bundled "asdf";
    }
  ];

  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "colors.lisp"
    "colornames-x11.lisp"
    "colornames-svg.lisp"
    "colornames-gdk.lisp"
    "hexcolors.lisp"
    "print.lisp"
  ];
}
