# Alexandria is one of the foundational Common Lisp libraries that
# pretty much everything depends on.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.alexandria;
in depot.nix.buildLisp.library {
  name = "alexandria";

  srcs = map (f: src + ("/alexandria-1/" + f)) [
    "package.lisp"
    "definitions.lisp"
    "binding.lisp"
    "strings.lisp"
    "conditions.lisp"
    "symbols.lisp"
    "macros.lisp"
    "functions.lisp"
    "io.lisp"
    "hash-tables.lisp"
    "control-flow.lisp"
    "lists.lisp"
    "types.lisp"
    "arrays.lisp"
    "sequences.lisp"
    "numbers.lisp"
    "features.lisp"
  ];
}
