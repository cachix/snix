# MD5 hash implementation
{ depot, pkgs, ... }:

with depot.nix;

let src = with pkgs; srcOnly sbcl.pkgs.md5;
in buildLisp.library {
  name = "md5";
  deps = [
    {
      sbcl = buildLisp.bundled "sb-rotate-byte";
      default = depot.third_party.lisp.flexi-streams;
    }
  ];
  srcs = [ (src + "/md5.lisp") ];
}
