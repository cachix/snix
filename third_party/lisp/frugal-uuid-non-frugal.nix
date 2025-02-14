{ depot, pkgs, ... }:

let
  inherit (depot.nix) buildLisp;
  inherit (pkgs.sbcl.pkgs.frugal-uuid) src;
in

buildLisp.library {
  # TODO(sterni): can't use / since name influences paths
  name = "frugal-uuid-non-frugal";

  deps = [
    depot.third_party.lisp.frugal-uuid
    depot.third_party.lisp.babel
    depot.third_party.lisp.bordeaux-threads
    depot.third_party.lisp.ironclad
    depot.third_party.lisp.trivial-clock
  ];

  # Note that these can be built individually, but we don't bother (yet)
  srcs = builtins.map (f: "${src}/non-frugal/${f}") [
    "strong-random"
    "thread-safe"
    "name-based"
    "accurate-clock"
    "minara"
  ];

  brokenOn = [
    "ecl" # trivial-clock
  ];
}
