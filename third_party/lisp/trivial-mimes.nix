{ depot, pkgs, ... }:

let
  src = with pkgs; srcOnly sbcl.pkgs.trivial-mimes;

  mime-types = pkgs.runCommand "mime-types.lisp" { } ''
    substitute ${src}/mime-types.lisp $out \
      --replace /etc/mime.types ${src}/mime.types \
      --replace "(asdf:system-source-directory :trivial-mimes)" '"/bogus-dir"'
      # We want to prevent an ASDF lookup at build time since this will
      # generally fail — we are not using ASDF after all.
  '';

in
depot.nix.buildLisp.library {
  name = "trivial-mimes";

  deps = [
    {
      sbcl = depot.nix.buildLisp.bundled "uiop";
      default = depot.nix.buildLisp.bundled "asdf";
    }
  ];

  srcs = [ mime-types ];
}
