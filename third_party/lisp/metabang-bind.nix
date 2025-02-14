{ depot, pkgs, ... }:

let
  getSrcs = builtins.map (p: "${pkgs.srcOnly pkgs.sbcl.pkgs.metabang-bind}/${p}");
in

depot.nix.buildLisp.library {
  name = "metabang-bind";

  srcs = getSrcs [
    "dev/packages.lisp"
    "dev/macros.lisp"
    "dev/bind.lisp"
    "dev/binding-forms.lisp"
  ];
}
