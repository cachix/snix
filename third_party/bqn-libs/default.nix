# - Standalone, importable files are installed to $out/lib/*.bqn.
#   They have no external dependencies, but do import each other (via relative paths).
# - Documentation to $out/share/doc/bqn-libs.
#
# Note: This packaging is ad hoc and tentative. No way to handle BQN dependencies
# for depot (or Nix, for that matter) has been proposed yet. If you have ideas /
# want to work on this, talk to sterni.
# TODO(sterni): Find out whether any work towards a BQN package manager exists
#
# The problem is that BQN is sort of like Nix: It only has the notion of direct
# file imports. Unlike Nix, however, it doesn't even have a builtin notion of a
# search path, so the design space is unconstrained. The most obvious solution
# would be to implement some kind of search part ourselves. Unfortunately, there
# is no portable way to access environment variables in BQN at the moment.
{ depot, pkgs, lib, ... }:

let
  src = pkgs.fetchFromGitHub {
    inherit (depot.third_party.sources.bqn-libs)
      repo
      owner
      sha256
      rev
      ;
  };
in

pkgs.runCommandNoCC "bqn-libs-${builtins.substring 0 7 src.rev}"
{
  nativeBuildInputs = [
    pkgs.cbqn
  ];
  meta.license = lib.licenses.bsd0;
} ''
  BQN "${src}/test/main.bqn"

  install -Dm644 "${src}/"*.bqn -t "$out/lib"
  install -Dm644 "${src}/LICENSE" -t "$out/share/doc/bqn-libs"
''
