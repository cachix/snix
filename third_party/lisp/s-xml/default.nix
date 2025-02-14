# XML serialiser for Common Lisp.
{ depot, pkgs, ... }:

let
  src = pkgs.applyPatches {
    name = "s-xml-source";
    src = pkgs.sbcl.pkgs.s-xml.src;

    patches = [
      ./0001-fix-definition-order-in-xml.lisp.patch
    ];
  };
in
depot.nix.buildLisp.library {
  name = "s-xml";

  srcs = map (f: src + ("/src/" + f)) [
    "package.lisp"
    "xml.lisp"
    "dom.lisp"
    "lxml-dom.lisp"
    "sxml-dom.lisp"
    "xml-struct-dom.lisp"
  ];
}
