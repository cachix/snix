{ pkgs, depot, ... }:

{
  shell = pkgs.mkShell {
    name = "tvix-website";
    packages = [
      pkgs.nodejs
      pkgs.hugo
    ];
  };

  website = depot.third_party.npmlock2nix.v2.build {
    pname = "snix-website";
    version = "0.0.0";

    src = depot.third_party.gitignoreSource ./.;

    installPhase = "cp -r public/. $out";
    buildCommands = [ "PATH=\"$PATH:${pkgs.hugo}/bin\" npm run build" ];
  };
}
