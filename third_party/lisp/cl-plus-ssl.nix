# Common Lisp bindings to OpenSSL
{ depot, pkgs, ... }:

with depot.nix;

let
  src = pkgs.srcOnly pkgs.sbcl.pkgs.cl_plus_ssl;
in

buildLisp.library {
  name = "cl-plus-ssl";
  deps = with depot.third_party.lisp; [
    alexandria
    bordeaux-threads
    cffi
    flexi-streams
    trivial-features
    trivial-garbage
    trivial-gray-streams
    usocket
    {
      scbl = buildLisp.bundled "uiop";
      default = buildLisp.bundled "asdf";
    }
    { sbcl = buildLisp.bundled "sb-posix"; }
  ];

  native = [ pkgs.openssl ];

  srcs = map (f: src + ("/src/" + f)) [
    "config.lisp"
    "package.lisp"
    "reload.lisp"
    "ffi.lisp"
    "bio.lisp"
    "conditions.lisp"
    "ssl-funcall.lisp"
    "init.lisp"
    "ffi-buffer-all.lisp"
    "ffi-buffer.lisp"
    "streams.lisp"
    "x509.lisp"
    "random.lisp"
    "context.lisp"
    "verify-hostname.lisp"
  ];

  brokenOn = [
    "ecl" # dynamic cffi
  ];
}
