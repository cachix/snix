# Portable pathname library
{ depot, pkgs, ... }:

with depot.nix;

let src = with pkgs; srcOnly sbcl.pkgs.cl-fad;
in buildLisp.library {
  name = "cl-fad";

  deps = with depot.third_party.lisp; [
    alexandria
    bordeaux-threads
    {
      sbcl = buildLisp.bundled "sb-posix";
    }
  ];

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
  ] ++ [
    { ccl = "${src}/openmcl.lisp"; }
  ] ++ map (f: src + ("/" + f)) [
    "fad.lisp"
    "path.lisp"
    "temporary-files.lisp"
  ];
}
