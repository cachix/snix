# split-sequence is a library for, well, splitting sequences apparently.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.split-sequence;
in depot.nix.buildLisp.library {
  name = "split-sequence";
  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "vector.lisp"
    "list.lisp"
    "extended-sequence.lisp"
    "api.lisp"
    "documentation.lisp"
  ];
}
