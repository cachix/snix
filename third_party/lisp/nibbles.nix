{ depot, pkgs, ... }:

let
  inherit (depot.nix.buildLisp) bundled;
  src = with pkgs; srcOnly (sbcl.pkgs.nibbles.overrideAttrs (oldAttrs: {
    patches = oldAttrs.patches or [ ] ++ [
      # Restoring the weird progn apparently fixes unbound MAKE-EA and EAX-OFFSET
      # which we were seeing during macroexpansion. Curiously, building niblbes
      # with ASDF is not affected by this problem.
      (pkgs.fetchpatch {
        name = "nibbles-sbcl-x86-restore-weird-progn.patch";
        url = "https://github.com/sharplispers/nibbles/commit/f37322b864ea12018bc0acbd70cb1e24bf0426eb.patch";
        revert = true;
        sha256 = "0h601g145qscmvykrzrf9bnlakfh5qawwmdd1z8f2cslfxrkj9jc";
      })
    ];
  }));
in
depot.nix.buildLisp.library {
  name = "nibbles";

  deps = with depot.third_party.lisp; [
    (bundled "asdf")
  ];

  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "types.lisp"
    "macro-utils.lisp"
    "vectors.lisp"
    "streams.lisp"
  ] ++ [
    { sbcl = "${src}/sbcl-opt/fndb.lisp"; }
    { sbcl = "${src}/sbcl-opt/nib-tran.lisp"; }
    { sbcl = "${src}/sbcl-opt/x86-vm.lisp"; }
    { sbcl = "${src}/sbcl-opt/x86-64-vm.lisp"; }
  ];
}
