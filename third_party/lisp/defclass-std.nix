# A shortcut macro to write DEFCLASS forms quickly
# Seems to be unmaintained (since early 2021)
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.defclass-std;
in depot.nix.buildLisp.library {
  name = "defclass-std";
  deps = with depot.third_party.lisp; [
    alexandria
    anaphora
  ];

  srcs = map (f: src + ("/src/" + f)) [
    "defclass-std.lisp"
  ];
}
