{ pkgs, depot, ... }:

{
  shell = pkgs.mkShell {
    name = "tvix-website";
    packages = [
      pkgs.nodejs
      pkgs.hugo
    ];
  };

  website = pkgs.buildNpmPackage {
    pname = "snix-website";
    version = "0.0.0";

    nativeBuildInputs = [
      pkgs.hugo
    ];

    src = depot.third_party.gitignoreSource ./.;

    npmDeps = pkgs.importNpmLock {
      npmRoot = ./.;
    };

    npmConfigHook = pkgs.importNpmLock.npmConfigHook;

    installPhase = "cp -r public/. $out";
  };
}
