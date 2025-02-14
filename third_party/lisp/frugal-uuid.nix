{ pkgs, depot, ... }:

let
  inherit (depot.nix) buildLisp;
  inherit (pkgs.sbcl.pkgs.frugal-uuid) src;

in

buildLisp.library {
  name = "frugal-uuid";
  srcs = builtins.map (f: "${src}/${f}.lisp") [
    "package"
    "frugal-uuid"
    "frugal-uuid-node"
    "frugal-uuid-clock"
    "frugal-uuid-random"
    "frugal-uuid-namespace"
    "frugal-uuid-v1"
    "frugal-uuid-v2"
    "frugal-uuid-v3"
    "frugal-uuid-v4"
    "frugal-uuid-v5"
    "frugal-uuid-v6"
    "frugal-uuid-v7"
    "frugal-uuid-v8"
  ];

  tests = {
    name = "frugal-uuid-test";
    srcs = [
      "${src}/frugal-uuid-test.lisp"
    ];
    deps = [
      depot.third_party.lisp.fiveam
    ];
    expression = ''
      (fiveam:run! :frugal-uuid)
    '';
  };
}
