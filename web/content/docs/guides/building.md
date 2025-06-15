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
Snix is hosted in its own Forgejo instance, hosted on [git.snix.dev](https://git.snix.dev/snix/snix).

Check out the source code as follows:

```bash
git clone https://git.snix.dev/snix/snix.git
```

### Interactive development
```bash
direnv allow
```

This provides all the necessary tools and dependencies to interactively build
the source code, using `cargo build` etc.

### Building only

It is also possible to build the different Snix crates with Nix,
in which you don't need to enter the shell.
From the root of the repository, you can build as follows:

```bash
$ nix-build -A snix.cli
```

Alternatively, you can use the `mg` wrapper from anywhere in the repository (requires the direnv setup from above):

```bash
mg build //snix:cli
```

This uses [crate2nix][] to build each crate dependency individually.

#### Binary cache for Development

If you want to fetch store paths built by CI, you can configure our
[Harmonia](https://github.com/nix-community/harmonia) deployment as a Nix substituter:

```nix
{
  nix.settings.trusted-public-keys = [
    "cache.snix.dev-1:miTqzIzmCbX/DyK2tLNXDROk77CbbvcRdWA4y2F8pno="
  ];
  nix.settings.substituters = [
    "https://cache.snix.dev"
  ];
}
```

Keep in mind there's no guarantees on paths being available, they get GC'ed
eventually.


### Further reading
Checkout the [Component Overview]({{< ref "/docs/components/overview" >}})
to learn more about the project structure.


[Direnv]: https://direnv.net
[direnv-inst]: https://direnv.net/docs/installation.html
[Nix]: https://nixos.org/nix/
[mg]: https://code.tvl.fyi/tree/tools/magrathea
[crate2nix]: https://github.com/nix-community/crate2nix/
