{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.physical-quantities;
in depot.nix.buildLisp.library {
  name = "physical-quantities";

  deps = with depot.third_party.lisp; [
    parseq
  ];

  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "utils.lisp"
    "conditions.lisp"
    "unit-factor.lisp"
    "unit-database.lisp"
    "units.lisp"
    "quantity.lisp"
    "numeric.lisp"
    "parse-rules.lisp"
    "read-macro.lisp"
    "si-units.lisp"
  ];
}
