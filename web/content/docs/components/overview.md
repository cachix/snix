---
title: "Component Overview"
slug: overview
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 32
toc: true
---

This diagram gives an overview over the different crates in the repository, the
different contained components and the dependencies in between them.

If you scroll further down, you find a textual description of what each component does.
Check the individual documentation pages for more details.

{{< inline-svg src="crate-diagram.svg" width="800px" height="800px" class="svg-inline-custom" >}}


## Castore
`snix-castore` is a content-addressed data storage / syncing engine.

It uses a merkle structure to store filesystem trees, as well as a chunked blob
storage for individual file contents.

It is not Nix-specific.


## Store
`snix-store` is a Nix store implementation using `snix-castore` for the
underlying data structure.

It only stores metadata like store path names, nar hashes, references,
signatures etc, and offloads content storage to `snix-castore`, by storing the
root node describing the contents.

There's also a CLI entrypoint that can be used to host a gRPC server endpoint,
copy into a store, or mount a store as a FUSE/virtiofs.

## Nix-Compat
`nix-compat` is a library providing access to various data formats, protocols
and concepts of Nix.

It does not depend on other Snix crates, making it a low-dependency crate to
include in other (non-snix) projects as well.

Other snix crates are usually the primary consumers and drive new functionality
in there - new formats etc. are usually "factored out into nix-compat".

## Builder
The builder consumes build requests from a client, runs builds and sends
logs/telemetry to the client.

There currently exists an OCI builder, as well as gRPC server adapter and client
implementations, allowing to run the builder both locally or remotely.

## Eval
`snix-eval` is a bytecode interpreter evaluator. It knows about basic Nix
language data structures and semantics, constructs bytecode and provides a VM
executing this bytecode.

It also provides some "core" builtins, though builtins are pluggable - you can
construct an evaluator and bring your own builtins.

It also defines the `EvalIO` trait and provides some very simple implementations
of it, which is how the evaluator does do IO.


## Glue
`snix-glue` provides some more builtins (those interacting with the Builder and
Store mostly).

It allows keeping `snix-eval` relatively simple.

## CLI
`snix-cli` is a REPL interface, constructing an Evaluator and populating it with
most builtins present in Nix. It is our main vehicle to evaluate Nixpkgs and
check for differences.

## Serde
`snix-serde` is a crate allowing (de)-serialisation of Rust data structures
to/from Nix. It allows you to use (a subset of) Nix as a configuration language
in/for your application.

## Tracing
`snix-tracing` contains some common tracing / logging / progress reporting code
that's used in various CLI entrypoints.

## Nar-Bridge
`nar-bridge` provides a Nix HTTP Binary cache server endpoint (read-write),
using `snix-[ca]store` to store the underlying data. It allows you to host your
own binary cache that Nix can talk to.

## Snixbolt
This uses `snix-eval`, providing a WASM bytecode explorer running in your
browser.
