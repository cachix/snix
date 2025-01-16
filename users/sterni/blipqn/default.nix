{ pkgs, lib, ... }:

let
  inherit (pkgs) llvmPackages;
  drv = llvmPackages.stdenv.mkDerivation {
    name = "blipqn";

    src = lib.cleanSource ./.;

    makeFlags = [ "PREFIX=$(out)" ];

    nativeBuildInputs = [
      llvmPackages.clang-tools
    ];

    buildInputs = [
      pkgs.cbqn
    ];

    doCheck = true;
    checkInputs = [
      pkgs.netcat-openbsd
    ];
    checkPhase = ''
      runHook preCheck
      nc -lu 2323 > raw &
      BQN ./examples.bqn localhost 2323 32 10 235
      kill %1
      base64 raw > received
      diff -u received - <<EOF
      AAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
      EOF
      runHook postCheck
    '';

    meta.ci.targets = [ "debug" ];
    passthru.debug = drv.overrideAttrs (old: {
      CFLAGS = "-g -Werror -DFLIPDOT_DEBUG=1";
    });
  };
in

drv
