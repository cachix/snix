{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-colors;
in depot.nix.buildLisp.library {
  name = "cl-colors";
  deps = [
    depot.third_party.lisp.alexandria
    depot.third_party.lisp.let-plus
  ];
  srcs = [
    "${src}/package.lisp"
    "${src}/colors.lisp"
    "${src}/colornames.lisp"
    "${src}/hexcolors.lisp"
  ];
}
