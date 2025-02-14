# Base64 encoding for Common Lisp
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-base64;
in depot.nix.buildLisp.library {
  name = "cl-base64";
  srcs = [
    (src + "/package.lisp")
    (src + "/encode.lisp")
    (src + "/decode.lisp")
  ];
}


