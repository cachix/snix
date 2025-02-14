# cl-ppcre is a Common Lisp regular expression library.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-ppcre;
in depot.nix.buildLisp.library {
  name = "cl-ppcre";

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "specials.lisp"
    "util.lisp"
    "errors.lisp"
    "charset.lisp"
    "charmap.lisp"
    "chartest.lisp"
    "lexer.lisp"
    "parser.lisp"
    "regex-class.lisp"
    "regex-class-util.lisp"
    "convert.lisp"
    "optimize.lisp"
    "closures.lisp"
    "repetition-closures.lisp"
    "scanner.lisp"
    "api.lisp"
  ];

  passthru = {
    unicode = depot.nix.buildLisp.library {
      name = "cl-ppcre-unicode";
      deps = with depot.third_party.lisp; [ cl-ppcre cl-unicode ];

      srcs = map (f: src + ("/cl-ppcre-unicode/" + f)) [
        "packages.lisp"
        "resolver.lisp"
      ];
    };
  };
}
