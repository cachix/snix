# Implementation of RFC2388 (multipart/form-data)
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.rfc2388;
in depot.nix.buildLisp.library {
  name = "rfc2388";

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "rfc2388.lisp"
  ];
}
