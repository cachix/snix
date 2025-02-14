# Flexible bivalent streams for Common Lisp
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.flexi-streams;
in depot.nix.buildLisp.library {
  name = "flexi-streams";
  deps = [ depot.third_party.lisp.trivial-gray-streams ];

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "mapping.lisp"
    "ascii.lisp"
    "koi8-r.lisp"
    "mac.lisp"
    "iso-8859.lisp"
    "enc-cn-tbl.lisp"
    "code-pages.lisp"
    "specials.lisp"
    "util.lisp"
    "conditions.lisp"
    "external-format.lisp"
    "length.lisp"
    "encode.lisp"
    "decode.lisp"
    "in-memory.lisp"
    "stream.lisp"
    "output.lisp"
    "input.lisp"
    "io.lisp"
    "strings.lisp"
  ];
}

