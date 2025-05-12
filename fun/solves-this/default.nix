{ pkgs, ... }:
let
  mkWebroot = title: imgsrc: pkgs.runCommand "webroot" { } ''
    mkdir -p $out
    title="${title}" substituteAll ${./index.html} $out/index.html
    cp ${imgsrc} $out/solves-this.png
  '';

in
{
  tvix = mkWebroot "Tvix solves this" ./tvix_solves_this.png;
  snix = mkWebroot "Snix solves this" ./snix_solves_this.png;
}
