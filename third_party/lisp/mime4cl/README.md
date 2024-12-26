# mime4cl

`MIME4CL` is a Common Lisp library for dealing with MIME messages. It was
originally been written by Walter C. Pelissero and vendored into depot
([mime4cl-20150207T211851.tbz](http://wcp.sdf-eu.org/software/mime4cl-20150207T211851.tbz)
to be exact) as upstream has become inactive. Its [original
website](http://wcp.sdf-eu.org/software/#mime4cl) can still be accessed.

The depot version has since diverged from upstream. Main aims were to improve
performance and reduce code size by relying on third party libraries like
flexi-streams. It is planned to improve encoding handling in the long term.
Work towards this happens intermittently.

WARNING:
mime4cl currently doesn't have a _comprehensive_ test suite
and decidedly lacks performance.

## Differences from the original version

* `//nix/buildLisp` is used as the build system. ASDF is currently untested and
  may be broken.

* The dependency on [sclf](http://wcp.sdf-eu.org/software/#sclf) has been
  eliminated by inlining the relevant parts.

* `MY-STRING-INPUT-STREAM`, `DELIMITED-INPUT-STREAM`,
  `CHARACTER-INPUT-ADAPTER-STREAM`, `BINARY-INPUT-ADAPTER-STREAM` etc. have been
  replaced by (thin wrappers around) flexi-streams. In addition to improved
  handling of encodings, this allows using `READ-SEQUENCE` via the gray stream
  interface.
