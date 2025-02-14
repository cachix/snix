{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.trivial-indent;
in depot.nix.buildLisp.library {
  name = "trivial-indent";

  srcs = map (f: src + ("/" + f)) [
    "indent.lisp"
  ];
}
