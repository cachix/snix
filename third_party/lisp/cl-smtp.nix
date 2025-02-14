{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-smtp;
in depot.nix.buildLisp.library {
  name = "cl-smtp";
  deps = with depot.third_party.lisp; [
    alexandria
    usocket
    flexi-streams
    frugal-uuid-non-frugal
    cl-base64
    cl-plus-ssl
  ];

  srcs = map (f: src + ("/" + f)) [
    "package.lisp"
    "attachments.lisp"
    "cl-smtp.lisp"
    "mime-types.lisp"
  ];

  brokenOn = [
    "ecl" # dynamic cffi
  ];
}
