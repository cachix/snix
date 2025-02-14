{ depot, pkgs, ... }:

let
  inherit (depot.nix) buildLisp;
  src = pkgs.srcOnly pkgs.sbcl.pkgs.trivial-clock;
in

buildLisp.library {
  name = "trivial-clock";

  srcs = [
    "${src}/trivial-clock.lisp"
  ];
  deps = [
    depot.third_party.lisp.cffi
  ];

  tests = {
    name = "trivial-clock-tests";
    deps = [
      depot.third_party.lisp.fiveam
    ];
    srcs = [
      "${src}/trivial-clock-test.lisp"
    ];
    expression = ''
      (fiveam:run! :trivial-clock)
    '';
  };

  brokenOn = [
    "ecl" # dyn cffi
  ];
}
