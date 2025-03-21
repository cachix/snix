---
title: "Building Snix"
slug: building
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 11
toc: true
---

This document describes how to build the project locally, both for interactive
development as well as referring to it from Nix code (for example, to run one of
its binaries on your machine).

{{<callout>}}
Please check the [Contribution Guide]({{< relref "contributing" >}}) on how to
contribute after following this guide.
{{</callout>}}

### Requirements
 - Ensure you have [Direnv][] installed and [hooked into your shell][direnv-inst].
 - Ensure you have [Nix][] installed.

### Getting the sources
Snix is hosted in its own Forgejo instance, hosted on [git.snix.dev](https://git.snix.dev/snix/snix), and a
(read-only) mirror on [GitHub](https://github.com/snix-project/snix).

Check out the source code as follows:

```console
$ git clone https://git.snix.dev/snix/snix.git
```

### Interactive development
```console
$ direnv allow
$ mg shell //snix:shell
```

This provides all the necessary tools and dependencies to interactively build
the source code, using `cargo build` etc.

### Building only

It is also possible to build the different Snix crates with Nix,
in which you don't need to enter the shell.
From the root of the repository, you can build as follows:

```console
$ nix-build -A snix.cli
```

Alternatively, you can use the `mg` wrapper from anywhere in the repository (requires the direnv setup from above):

```console
$ mg build //snix:cli
```

This uses [crate2nix][] to build each crate dependency individually.

Checkout the [Component Overview]({{< ref "/docs/components/overview" >}})
to learn more about the project structure.


[Direnv]: https://direnv.net
[direnv-inst]: https://direnv.net/docs/installation.html
[Nix]: https://nixos.org/nix/
[mg]: https://code.tvl.fyi/tree/tools/magrathea
[crate2nix]: https://github.com/nix-community/crate2nix/


