{ pkgs, ... }:


let
  zmk-nix = pkgs.fetchFromGitHub {
    owner = "lilyinstarlight";
    repo = "zmk-nix";
    rev = "d72e94ab94b2bceb60a29a2a8c2e1d304a4e922e";
    hash = "sha256-3WXPPBJ2u8rMxejPhUahSiqOBr1BOfTgDa7oQDPtw54=";
  };

  zmk_builders = pkgs.callPackage (import (zmk-nix + "/nix/builders.nix")) { };

  miryoku_zmk = pkgs.fetchFromGitHub {
    owner = "manna-harbour";
    repo = "miryoku_zmk";
    rev = "e6683e9f8b6c199b339208b1b501e88a7308ed48";
    hash = "sha256-GjTbAoyhr557Tn4JaWsA3Po5KxMsQXrpKc9H+PU3T8A=";
  };

  miryoku_zmk_patched = pkgs.runCommand "miryoku_zmk_patched" { } ''
    mkdir -p $out
    cp -r ${miryoku_zmk}/. $out/
    cd $out
    chmod -R +w $out
    patch -p1 < ${./0001-miryoku_layer_alternatives.h-expose-alt-gr-on-G-and-.patch}
    patch -p1 < ${./0001-miryoku_behaviors-add-quick-tap-ms-require-prior-idl.patch}
  '';

  miryoku_config = pkgs.runCommand "config" { } ''
    mkdir -p $out/config
    cp -r ${miryoku_zmk_patched}/miryoku $out/
    cp ${./west.yml} $out/config/west.yml
    cp ${miryoku_zmk_patched}/config/*.keymap $out/config/
  '';

  # helpful for debugging a resulting keymap config
  mkFlatConfig = name: pkgs.runCommand "config-flat"
    {
      nativeBuildInputs = [ pkgs.python3.pkgs.pcpp ];
    } ''
    mkdir -p $out/config
    cp ${./west.yml} $out/config/west.yml
    pcpp --passthru-unfound-includes -o $out/config/${name}.keymap ${miryoku_zmk_patched}/config/${name}.keymap
  '';

in

{
  miryoku_zmk = miryoku_zmk_patched;
  inherit (zmk_builders) buildSplitKeyboard;
  inherit miryoku_config mkFlatConfig;
}
