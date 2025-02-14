# This library is meant to make writing portable multi-threaded apps
# in Common Lisp simple.
{ depot, pkgs, ... }:

let
  src = with pkgs; srcOnly sbcl.pkgs.bordeaux-threads;
  getSrc = f: "${src}/${f}";
in
depot.nix.buildLisp.library {
  name = "bordeaux-threads";
  deps = [
    depot.third_party.lisp.alexandria
    depot.third_party.lisp.global-vars
    depot.third_party.lisp.trivial-features
    depot.third_party.lisp.trivial-garbage
  ];

  srcs = map getSrc [
    "apiv1/pkgdcl.lisp"
    "apiv1/bordeaux-threads.lisp"
  ] ++ [
    {
      sbcl = getSrc "apiv1/impl-sbcl.lisp";
      ecl = getSrc "apiv1/impl-ecl.lisp";
      ccl = getSrc "apiv1/impl-clozure.lisp";
    }
  ] ++ map getSrc [
    "apiv1/default-implementations.lisp"

    "apiv2/pkgdcl.lisp"
    "apiv2/bordeaux-threads.lisp"
    "apiv2/timeout-interrupt.lisp"
  ] ++ [
    {
      sbcl = getSrc "apiv2/impl-sbcl.lisp";
      ecl = getSrc "apiv2/impl-ecl.lisp";
      ccl = getSrc "apiv2/impl-clozure.lisp";
    }
    (getSrc "apiv2/api-locks.lisp")
    (getSrc "apiv2/api-threads.lisp")
    (getSrc "apiv2/api-semaphores.lisp")
    {
      ccl = getSrc "apiv2/impl-condition-variables-semaphores.lisp";
    }
    (getSrc "apiv2/api-condition-variables.lisp")
  ];
}
