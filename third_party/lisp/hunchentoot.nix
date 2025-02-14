# Hunchentoot is a web framework for Common Lisp.
{ depot, pkgs, lib, ... }:

let
  src = with pkgs; srcOnly sbcl.pkgs.hunchentoot;

  url-rewrite = depot.nix.buildLisp.library {
    name = "url-rewrite";

    srcs = map (f: src + ("/url-rewrite/" + f)) [
      "packages.lisp"
      "specials.lisp"
      "primitives.lisp"
      "util.lisp"
      "url-rewrite.lisp"
    ];
  };
in
depot.nix.buildLisp.library {
  name = "hunchentoot";

  deps = with depot.third_party.lisp; [
    alexandria
    bordeaux-threads
    chunga
    cl-base64
    cl-fad
    rfc2388
    cl-plus-ssl
    cl-ppcre
    flexi-streams
    md5
    trivial-backtrace
    usocket
    url-rewrite
  ];

  srcs = map (f: src + ("/" + f)) [
    "packages.lisp"
    "compat.lisp"
  ] ++ [
    (pkgs.runCommand "specials.lisp" { } ''
      substitute "${src}/specials.lisp" "$out" --replace-fail \
        ${lib.escapeShellArg "#.(asdf:component-version (asdf:find-system :hunchentoot))"} \
        '"${lib.removePrefix "v" src.version}"'
    '')
  ] ++ map (f: src + ("/" + f)) [
    "conditions.lisp"
    "mime-types.lisp"
    "util.lisp"
    "log.lisp"
    "cookie.lisp"
    "reply.lisp"
    "request.lisp"
    "session.lisp"
    "misc.lisp"
    "headers.lisp"
    "set-timeouts.lisp"
    "taskmaster.lisp"
    "ssl.lisp"
    "acceptor.lisp"
    "easy-handlers.lisp"
  ];

  brokenOn = [
    "ecl" # dynamic cffi
  ];
}
