depot
=====

[![Build status](https://badge.buildkite.com/016bff4b8ae2704a3bbbb0a250784e6692007c582983b6dea7.svg?branch=refs/heads/canon)](https://buildkite.com/tvl/depot)

This repository is the [monorepo][] for the community around [The
Virus Lounge][tvl], containing our personal tools and infrastructure.
Everything in here is built using [Nix][].

A large portion of the software here is very self-referential, meaning that it
exists to sustain the operation of the repository. This is the case because we
partially see this as [an experiment][] in tooling for monorepos.

# Highlights

## Services

* Source code can be viewed primarily via `cgit-pink` on
  [code.tvl.fyi](https://code.tvl.fyi), with code search being available through
  Livegrep on [grep.tvl.fyi](https://grep.tvl.fyi).

  The repository can be cloned using `git` from `https://cl.tvl.fyi/depot`.

* All code in the depot, with the exception of code that is checked in to
  individual `//users` folders, needs to be reviewed. We use Gerrit on
  [cl.tvl.fyi](https://cl.tvl.fyi) for this.

* Issues are tracked via our own issue tracker on
  [b.tvl.fyi](https://b.tvl.fyi). Its source code lives at
  [`//web/panettone/`][panettone].

* Smaller todo-list entries which do not warrant a separate issue are listed at
  [todo.tvl.fyi](https://todo.tvl.fyi).

* We use Buildkite for CI. Recent builds are listed on
  [tvl.fyi/builds](https://tvl.fyi/builds) and pipelines are configured
  dynamically via
  [`//ops/pipelines`](https://cs.tvl.fyi/depot/-/tree/ops/pipelines).

* A search service that makes TVL services available via textual
  shortcuts is available: [atward](https://at.tvl.fyi)

All services that we host are deployed on NixOS machines that we manage. Their
configuration is tracked in `//ops/{modules,machines}`.

## Nix

* [`//nix/readTree`](https://cs.tvl.fyi/depot/-/blob/nix/readTree/README.md)
  contains the Nix code which automatically registers projects in our Nix
  attribute hierarchy based on their in-tree location
* [`//tools/nixery`](https://cs.tvl.fyi/depot/-/tree/tools/nixery)
  contains the source code of [Nixery][], a container registry that
  can build images ad-hoc from Nix packages
* `//nix/yants` contains **Y**et **A**nother **N**ix **T**ype **S**ystem, which
  we use for a variety of things throughout the repository
* `//nix/buildGo` implements a Nix library that can build Go software in the
  style of Bazel's `rules_go`. Go programs in this repository are built using
  this library.
* `//nix/buildLisp` implements a Nix library that can build Common Lisp
  software. Currently only SBCL is supported. Lisp programs in this repository
  are built using this library.
* `//web/blog` and `//web/atom-feed`: A Nix-based static site generator which
  generates the web page and Atom feed for [tazj.in](https://tazj.in)
  (`//users/tazjin/homepage`) and [tvl.fyi](https://tvl.fyi) (`//web/tvl`)
* `//web/bubblegum` contains a CGI-based web framework written in Nix.
* `//nix/nint`: A shebang-compatible interpreter wrapper for Nix.
* `//tvix` contains initial work towards a modular architecture for Nix.

We have a variety of other tools and libraries in the `//nix` folder which may
be of interest.

## Packages / Libraries

* `//net/alcoholic_jwt` contains an easy-to-use JWT-validation library for Rust
* `//net/crimp` contains a high-level HTTP client using cURL for Rust
* `//tools/emacs-pkgs` contains various useful Emacs libraries, for example:
  * `dottime.el` provides [dottime][] in the Emacs modeline
  * `nix-util.el` provides editing utilities for Nix files
  * `term-switcher.el` is an ivy-function for switching between vterm buffers
  * `tvl.el` provides helper functions for interacting with the TVL monorepo
* `//lisp/klatre` provides a grab-bag utility library for Common Lisp

## User packages

Contributors to the repository have user directories under
[`//users`](https://cs.tvl.fyi/depot@canon/-/tree/users), which can be used for
personal or experimental code that does not require review.

Some examples:

* `//users/aspen/xanthous`: A (WIP) TUI RPG, written in Haskell.
* `//users/tazjin/emacs`: tazjin's Emacs & EXWM configuration
* `//users/tazjin/finito`: A persistent finite-state machine library for Rust.

# Licensing

Unless otherwise stated in a subdirectory, all code is licensed under the MIT
license. See [LICENSE](./LICENSE) for details.

# Contributing

If you'd like to contribute to any of the tools in here, please check out the
[contribution guidelines](./docs/CONTRIBUTING.md) and our [code of
conduct](./docs/CODE_OF_CONDUCT.md).

IRC users can find us in [`#tvl`][tvl-irc] on [hackint][], which is also
reachable [via XMPP][hackint-xmpp] at [`#tvl@irc.hackint.org`][tvl-xmpp] (sic!).

Hackint also provide a [web chat][tvl-webchat].

[monorepo]: https://en.wikipedia.org/wiki/Monorepo
[tvl]: https://tvl.fyi
[Nix]: https://nixos.org/nix
[an experiment]: https://tvl.fyi/monorepo-doc
[panettone]: https://cs.tvl.fyi/depot@canon/-/tree/web/panettone
[dottime]: https://dotti.me
[tvl-irc]: ircs://irc.hackint.org:6697/#tvl
[hackint]: https://hackint.org/
[hackint-xmpp]: https://hackint.org/transport/xmpp
[tvl-xmpp]: xmpp:#tvl@irc.hackint.org?join
[tvl-webchat]: https://webirc.hackint.org/#ircs://irc.hackint.org/#tvl
[Nixery]: https://nixery.dev
