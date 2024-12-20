{ depot, pkgs, lib, ... }:

let
  runtimeDependencies = [
    depot.users.sterni.mn2html
    pkgs.mblaze
    pkgs.execline # execline-cd
  ];

  buildInputs = [
    pkgs.cbqn
  ];
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
  };
}
  ''
    install -Dm755 "$src" "$out/bin/blërg"
    patchShebangs "$out/bin/blërg"
    wrapProgram "$out/bin/blërg" --prefix PATH : "${lib.makeBinPath runtimeDependencies}"
  ''
