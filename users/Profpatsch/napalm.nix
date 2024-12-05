{ pkgs, ... }:
import
  (builtins.fetchGit {
    url = "https://github.com/nix-community/napalm";
    rev = "e1babff744cd278b56abe8478008b4a9e23036cf";
  })
{
  inherit pkgs;
}
