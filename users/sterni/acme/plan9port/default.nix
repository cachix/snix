{ depot, pkgs, lib, ... }:

let
  patchesFromDir = dir:
    lib.filter
      (lib.hasSuffix ".patch")
      (lib.mapAttrsToList
        (name: _: dir + "/${name}")
        (builtins.readDir dir));

  mkbqnkeyboard' = pkgs.writeShellScript "mkbqnkeyboard'" ''
    exec ${pkgs.cbqn}/bin/BQN ${../mkbqnkeyboard.bqn} -si \
      "${pkgs.srcOnly pkgs.mbqn}/editors/inputrc" "$1"
  '';

  inherit (depot.users.sterni.acme) plan9port;
in

pkgs.plan9port.overrideAttrs (old: {
  patches = old.patches or [ ] ++ patchesFromDir ./.;
  postPatch = old.postPatch or "" + ''
    ${mkbqnkeyboard'} lib/keyboard

    cp --reflink=auto ${./../plumb}/* plumb/
    mv plumb/sterni.plumbing plumb/initial.plumbing
  '';

  passthru = old.passthru or { } // {
    wrapper =
      let
        PLAN9 = "${plan9port}/plan9";
        globalBins = [
          "9p"
          "9pfuse"
        ];
      in
      pkgs.runCommandNoCC "${old.pname}-wrapper-${old.version}"
        {
          nativeBuildInputs = [
            pkgs.buildPackages.makeWrapper
          ];
        }
        ''
          mkdir -p "$out/bin"

          ln -s "${plan9port}/bin/9" "$out/bin/"
          for cmd in ${lib.escapeShellArgs globalBins}; do
            makeWrapper "${PLAN9}/bin/$cmd" "$out/bin/$cmd" \
              --set PLAN9 "${PLAN9}"
          done

        '';
  };

  postInstall = ''
    echo '48.3626 10.9026 483\
    (OpenLab Augsburg)' > $out/plan9/sky/here
  '';

  doInstallCheck = true;
  installCheckPhase = old.installCheckPhase or "" + ''
    export NAMESPACE="$(mktemp -d)"
    "$out/bin/9" plumber -f &
    pid="$!"
    until [[ -e "$NAMESPACE/plumb" ]]; do
      sleep 0.1
    done
    "$out/bin/9" 9p write plumb/rules < ${./../plumb}/sterni.plumbing
    kill "$pid"
  '';

  meta = old.meta or { } // {
    ci.targets = [ "wrapper" ];
  };
})
