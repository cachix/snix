{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.parse-float;
in depot.nix.buildLisp.library {
  name = "parse-float";

  deps = with depot.third_party.lisp; [
    alexandria
  ];

  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "parse-float.lisp"
  ];
}
