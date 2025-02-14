# trivial-garbage provides a portable API to finalizers, weak
# hash-tables and weak pointers
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.trivial-garbage;
in depot.nix.buildLisp.library {
  name = "trivial-garbage";
  srcs = [ (src + "/trivial-garbage.lisp") ];
}
