# Library for manipulating dates & times
{ depot, pkgs, ... }:

let
  inherit (depot.nix) buildLisp;
  src = with pkgs; srcOnly sbcl.pkgs.local-time;
in
buildLisp.library {
  name = "local-time";
  deps = [
    depot.third_party.lisp.cl-fad
    {
      scbl = buildLisp.bundled "uiop";
      default = buildLisp.bundled "asdf";
    }
  ];

  srcs = [
    "${src}/src/package.lisp"
    "${src}/src/local-time.lisp"
  ];
}
