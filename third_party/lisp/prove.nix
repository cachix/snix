{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.prove;
in depot.nix.buildLisp.library {
  name = "prove";

  deps = [
    depot.third_party.lisp.alexandria
    depot.third_party.lisp.cl-ansi-text
    depot.third_party.lisp.cl-colors
    depot.third_party.lisp.cl-ppcre
    (depot.nix.buildLisp.bundled "asdf")
  ];

  srcs = [
    "${src}/src/color.lisp"
    "${src}/src/output.lisp"
    "${src}/src/asdf.lisp"
    "${src}/src/report.lisp"
    "${src}/src/reporter.lisp"
    "${src}/src/reporter/fiveam.lisp"
    "${src}/src/reporter/list.lisp"
    "${src}/src/reporter/dot.lisp"
    "${src}/src/reporter/tap.lisp"
    "${src}/src/suite.lisp"
    "${src}/src/test.lisp"
    "${src}/src/prove.lisp"
  ];
}
