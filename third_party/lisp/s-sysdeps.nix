# A Common Lisp abstraction layer over platform dependent functionality.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.s-sysdeps;
in depot.nix.buildLisp.library {
  name = "s-sysdeps";

  srcs = [
    "${src}/src/package.lisp"
    "${src}/src/sysdeps.lisp"
  ];

  deps = with depot.third_party.lisp; [
    bordeaux-threads
    usocket
    usocket-server
  ];
}
