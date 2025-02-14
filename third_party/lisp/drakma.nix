# Drakma is an HTTP client for Common Lisp.
{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.drakma;
in depot.nix.buildLisp.library {
  name = "drakma";
  deps = with depot.third_party.lisp; [
    chipz
    chunga
    cl-base64
    cl-plus-ssl
    cl-ppcre
    flexi-streams
    puri
    usocket
    (depot.nix.buildLisp.bundled "asdf")
  ];

  srcs = map (f: src + ("/" + f)) [
    "drakma.asd" # Required because the system definition is used
    "packages.lisp"
    "specials.lisp"
    "conditions.lisp"
    "util.lisp"
    "read.lisp"
    "cookies.lisp"
    "encoding.lisp"
    "request.lisp"
  ];

  brokenOn = [
    "ecl" # dynamic cffi
  ];
}
