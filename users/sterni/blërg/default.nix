{ depot, pkgs, lib, ... }:

let
  # update README.md when changing this
  runtimeDependencies = [
    depot.users.sterni.mn2html
    pkgs.mblaze
    pkgs.execline # execline-cd, importas, pipeline
    # coreutils   # for printf (assumed to be installed)
    pkgs.pandoc
    pkgs.lowdown
  ];

  # … and this
  buildInputs = [
    pkgs.cbqn
  ];

  BQN_LIBS = depot.third_party.bqn-libs + "/lib";
in

pkgs.runCommandNoCC "blerg"
{
  src = builtins.path {
    name = "blerg.bqn";
    path = ./. + "/blërg.bqn";
  };
  nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ];
  inherit buildInputs;
  passthru.shell = pkgs.mkShell {
    name = "blërg-shell";
    packages = runtimeDependencies ++ buildInputs;
    inherit BQN_LIBS;
  };
}
  ''
    install -Dm755 "$src" "$out/bin/blërg"
    patchShebangs "$out/bin/blërg"
    wrapProgram "$out/bin/blërg" \
      --prefix PATH : "${lib.makeBinPath runtimeDependencies}" \
      --set BQN_LIBS "${BQN_LIBS}"
  ''
