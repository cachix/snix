# Common Lisp library for decompressing deflate, zlib, gzip, and bzip2 data
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.chipz;
in depot.nix.buildLisp.library {
  name = "chipz";
  deps = [ (depot.nix.buildLisp.bundled "asdf") ];

  srcs = map (f: src + ("/" + f)) [
    "chipz.asd"
    "package.lisp"
    "constants.lisp"
    "conditions.lisp"
    "dstate.lisp"
    "types-and-tables.lisp"
    "crc32.lisp"
    "adler32.lisp"
    "inflate-state.lisp"
    "gzip.lisp"
    "zlib.lisp"
    "inflate.lisp"
    "bzip2.lisp"
    "decompress.lisp"
    "stream.lisp"
  ];
}
