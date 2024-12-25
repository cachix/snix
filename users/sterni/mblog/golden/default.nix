# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2024 by sterni
{ depot, pkgs, lib, ... }:

let
  maildir = pkgs.runCommandNoCC "mblog-golden-example-maildir" { } ''
    mkdir -p "$out/cur"
    cp --reflink=auto \
      "${depot.path.origSrc + "/third_party/lisp/mime4cl/test/samples/mail-note-from-notes-app.msg"}" \
      "$out/cur/1732277542.274467_1.wolfgang,U=1:2,S"
    cp --reflink=auto \
      "${depot.path.origSrc + "/third_party/lisp/mime4cl/test/samples/mail-note-from-notemap.msg"}" \
      "$out/cur/1735167350.823243_1.wolfgang,U=32:2,S"
  '';

  # Make golden test based on the given mblog derivation and add subtarget
  # golden tests for all meta.ci.targets.
  makeGoldenTest = mblog:
    pkgs.runCommand "mblog-golden-tests"
      {
        passthru = {
          inherit maildir;
        } // lib.mapAttrs (_: makeGoldenTest) (
          lib.attrsets.getAttrs mblog.meta.ci.targets mblog
        );

        nativeBuildInputs = [
          mblog
        ];

        meta.ci = {
          inherit (mblog.meta.ci) targets;
        };
      }
      ''
        mkdir -p actual
        mblog ${maildir} actual

        diff --color=always -ru ${./expected} actual
        touch "$out"
      '';
in

makeGoldenTest depot.users.sterni.mblog
