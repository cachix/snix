{ depot, pkgs, ... }:

let src = with pkgs; srcOnly sbcl.pkgs.cl-change-case;
in depot.nix.buildLisp.library {
  name = "cl-change-case";

  deps = with depot.third_party.lisp; [ cl-ppcre cl-ppcre.unicode ];

  srcs = [ (src + "/src/cl-change-case.lisp") ];

  tests = {
    name = "cl-change-case-tests";
    srcs = [ (src + "/t/cl-change-case.lisp") ];
    deps = [
      depot.third_party.lisp.fiveam
    ];

    expression = ''
      (5am:run! :cl-change-case)
    '';
  };
}
