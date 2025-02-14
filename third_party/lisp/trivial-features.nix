{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.trivial-features;
in depot.nix.buildLisp.library {
  name = "trivial-features";
  srcs = [
    {
      sbcl = src + "/src/tf-sbcl.lisp";
      ecl = src + "/src/tf-ecl.lisp";
      ccl = src + "/src/tf-openmcl.lisp";
    }
  ];
}
