# Portable chunked streams for Common Lisp
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.chunga;
in depot.nix.buildLisp.library {
  name = "chunga";
  deps = with depot.third_party.lisp; [
    trivial-gray-streams
  ];

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "specials.lisp"
    "util.lisp"
    "known-words.lisp"
    "conditions.lisp"
    "read.lisp"
    "streams.lisp"
    "input.lisp"
    "output.lisp"
  ];
}
