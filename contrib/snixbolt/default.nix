{
  pkgs,
  lib,
  depot,
  ...
}:
let
  pkgsCross = pkgs.pkgsCross.wasm32-unknown-none;
  # FUTUREWORK: point back to latest, currently fails with
  # "failed to find the `__wbindgen_externref_table_dealloc` function"
  wasm-bindgen-cli = pkgs.wasm-bindgen-cli_0_2_100;
in
(pkgsCross.callPackage ./Cargo.nix {
  defaultCrateOverrides = (depot.snix.utils.defaultCrateOverridesForPkgs pkgsCross) // {
    snixbolt = prev: {
      src = depot.snix.utils.filterRustCrateSrc { root = prev.src.origSrc; };
    };
  };
}).rootCrate.build.overrideAttrs
  (oldAttrs: {
    installPhase = ''
      ${lib.getExe wasm-bindgen-cli} \
        --target web \
        --out-dir $out \
        --out-name ${oldAttrs.crateName} \
        --no-typescript \
        target/lib/${oldAttrs.crateName}-${oldAttrs.metadata}.wasm

        mv src/*.{html,css} $out
    '';

    passthru.serve = pkgs.writeShellScriptBin "snixbolt-serve" ''
      ${lib.getExe pkgs.simple-http-server} \
          --index \
          --nocache \
          "$@" \
          ${depot.contrib.snixbolt}
    '';

    meta.ci.extraSteps.crate2nix-check = depot.snix.utils.mkCrate2nixCheck ./Cargo.nix;
  })
