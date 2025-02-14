{ depot, pkgs, ... }:

let
  inherit (depot.nix.buildLisp) bundled;
  src = with pkgs; srcOnly sbcl.pkgs.postmodern;

  cl-postgres = depot.nix.buildLisp.library {
    name = "cl-postgres";
    deps = with depot.third_party.lisp; [
      md5
      split-sequence
      ironclad
      cl-base64
      uax-15
      usocket
    ];

    srcs = map (f: src + ("/cl-postgres/" + f)) [
      "package.lisp"
      "features.lisp"
      "config.lisp"
      "oid.lisp"
      "errors.lisp"
      "data-types.lisp"
      "sql-string.lisp"
      "trivial-utf-8.lisp"
      "strings-utf-8.lisp"
      "communicate.lisp"
      "messages.lisp"
      "ieee-floats.lisp"
      "interpret.lisp"
      "saslprep.lisp"
      "scram.lisp"
      "protocol.lisp"
      "public.lisp"
      "bulk-copy.lisp"
    ];
  };

  s-sql = depot.nix.buildLisp.library {
    name = "s-sql";
    deps = with depot.third_party.lisp; [
      cl-postgres
      alexandria
    ];

    srcs = map (f: src + ("/s-sql/" + f)) [
      "package.lisp"
      "config.lisp"
      "s-sql.lisp"
    ];
  };

  postmodern = depot.nix.buildLisp.library {
    name = "postmodern";

    deps = with depot.third_party.lisp; [
      alexandria
      cl-postgres
      s-sql
      global-vars
      split-sequence
      cl-unicode
      closer-mop
      bordeaux-threads
    ];

    srcs = [
      "${src}/postmodern.asd"
    ] ++ (map (f: src + ("/postmodern/" + f)) [
      "package.lisp"
      "config.lisp"
      "connect.lisp"
      "json-encoder.lisp"
      "query.lisp"
      "prepare.lisp"
      "roles.lisp"
      "util.lisp"
      "transaction.lisp"
      "namespace.lisp"
      "execute-file.lisp"
      "table.lisp"
      "deftable.lisp"
    ]);

    brokenOn = [
      "ecl" # TODO(sterni): https://gitlab.com/embeddable-common-lisp/ecl/-/issues/651
    ];
  };

in
postmodern // {
  inherit s-sql cl-postgres;
}
