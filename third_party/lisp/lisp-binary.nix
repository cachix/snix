# A library to easily read and write complex binary formats.
{ depot, pkgs, ... }:

let
  src = pkgs.srcOnly pkgs.sbcl.pkgs.lisp-binary;
in
depot.nix.buildLisp.library {
  name = "lisp-binary";

  deps = with depot.third_party.lisp; [
    alexandria
    cffi
    closer-mop
    flexi-streams
    moptilities
    quasiquote_2
  ];

  srcs = map (f: src + ("/" + f)) [
    "utils.lisp"
    "integer.lisp"
    "float.lisp"
    "simple-bit-stream.lisp"
    "reverse-stream.lisp"
    "binary-1.lisp"
    "binary-2.lisp"
    "types.lisp"
  ];

  brokenOn = [
    "ecl" # TODO(sterni): disable conditionally cffi for ECL
  ];
}
