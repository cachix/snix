{ depot, pkgs, ... }:

let
  inherit (depot.nix) buildLisp;
  src = with pkgs; srcOnly sbcl.pkgs.str;
in
buildLisp.library {
  name = "str";

  deps = with depot.third_party.lisp; [
    {
      sbcl = buildLisp.bundled "uiop";
      default = buildLisp.bundled "asdf";
    }
    cl-ppcre
    cl-ppcre.unicode
    cl-change-case
  ];

  srcs = [
    (pkgs.runCommand "str.lisp" { } ''
      substitute ${src}/str.lisp $out \
        --replace-fail \
          '(asdf:component-version (asdf:find-system "str"))' \
          '"${pkgs.sbcl.pkgs.str.version}"'
    '')
  ];

  brokenOn = [
    "ccl" # In REPLACE-USING: Shouldn't assign to variable I
  ];

  tests = {
    name = "str-test";
    srcs = [ (src + "/test/test-str.lisp") ];
    deps = [
      {
        sbcl = depot.nix.buildLisp.bundled "uiop";
        default = depot.nix.buildLisp.bundled "asdf";
      }
      depot.third_party.lisp.prove
      depot.third_party.lisp.fiveam
    ];

    expression = ''
      (fiveam:run! 'str::test-str)
    '';
  };
}
