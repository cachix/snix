# Universal socket library for Common Lisp (server side)
{ depot, pkgs, ... }:

let
  inherit (depot.nix) buildLisp;
  src = with pkgs; srcOnly sbcl.pkgs.usocket-server;
in
buildLisp.library {
  name = "usocket-server";

  deps = with depot.third_party.lisp; [
    usocket
    bordeaux-threads
  ];

  srcs = [
    "${src}/server.lisp"
  ];
}
