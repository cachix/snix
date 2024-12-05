# Copyright (C) 2021 by the TVL Authors
# SPDX-License-Identifier: LGPL-2.1-or-later
{ depot, pkgs, ... }:

depot.nix.buildLisp.library {
  name = "mime4cl";

  deps = [
    depot.third_party.lisp.flexi-streams
    depot.third_party.lisp.npg
    depot.third_party.lisp.trivial-gray-streams
    depot.third_party.lisp.qbase64
    { sbcl = depot.nix.buildLisp.bundled "sb-posix"; }
  ];

  srcs = [
    ./ex-sclf.lisp
    ./package.lisp
    ./endec.lisp
    ./streams.lisp
    ./mime.lisp
    ./address.lisp
  ];

  tests = {
    name = "mime4cl-tests";

    srcs = [
      ./test/rt.lisp
      ./test/package.lisp
      (pkgs.writeText "nix-samples.lisp" ''
        (in-package :mime4cl-tests)

        ;; override auto discovery which doesn't work in the nix store
        (defvar *samples-directory* (pathname "${./test/samples}/"))
      '')
      ./test/temp-file.lisp
      ./test/endec.lisp
      ./test/address.lisp
      ./test/mime.lisp
    ];

    expression = "(rtest:do-tests)";
  };
}
