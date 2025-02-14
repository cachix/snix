{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.global-vars;
in depot.nix.buildLisp.library {
  name = "global-vars";
  srcs = [ "${src}/global-vars.lisp" ];
}
