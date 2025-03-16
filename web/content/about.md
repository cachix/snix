---
title: "About Snix"
slug: about
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 999
toc: false
---

<center>
{{< inline-svg src="snix-logo.svg" width="200px" height="200px" class="svg-inline-custom svg-monochrome" >}}
</center>

Snix is a modern Rust re-implementation of the components of the Nix package
manager.

Snix modularity & composability allows recombining its parts in novel ways. It
also provides library access to Nix data formats and concepts. In the long-run,
Snix aims to produce a Nixpkgs-compatible alternative to [NixOS/nix][] with
respects to evaluation and building Nix expressions & systems.

{{< callout >}}
Snix still is in its early stages of development. None of our current APIs
should be considered stable in any way.

There is no full-featured drop-in replacement for Nix on your machine yet.
{{</callout>}}

Snix already provides a few binaries / tools exposing some usecases, such as:

 * A `snix-store` binary, providing access to `snix-[ca]store`
   *  run a gRPC daemon exposing contents to other parties
   *  import local files or copy store paths into `snix-store`
   *  provide FUSE or virtiofs views into `snix-store`.
 * `nar-bridge`, a Nix HTTP Binary Cache frontend for `snix-store`.
    It allows Nix to interact with `snix-store`, both to substitute from as well
    as copy into.
 * `snix-boot`, tooling to boot microVMs off of `snix-store` (using virtiofs)
 * `snix-cli`, combining various components together to provide a Nix evaluator
    CLI and REPL.
 * `snixbolt`, a version of the Snix evaluator running in your browser (using
   WASM)

{{<callout>}}
Early adopters are encouraged to use (and extend) Snix to solve their
own usecases.
If you're missing certain functionality, or run into bugs, [reach out](),
so we can coordinate how to add/fix it.
{{</callout>}}

Snix is developed as a GPLv3-licensed free software project with source code
available on [our own Forgejo](https://git.snix.dev/) instance.

[NixOS/nix]: https://github.com/NixOS/nix
