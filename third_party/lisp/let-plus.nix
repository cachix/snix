{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.let-plus;
in depot.nix.buildLisp.library {
  name = "let-plus";
  deps = [
    depot.third_party.lisp.alexandria
    depot.third_party.lisp.anaphora
  ];
  srcs = [
    "${src}/package.lisp"
    "${src}/let-plus.lisp"
    "${src}/extensions.lisp"
  ];
}
