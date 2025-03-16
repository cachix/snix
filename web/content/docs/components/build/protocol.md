---
title: "Protocol"
slug: protocol
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 41
toc: true
---

One goal of the builder protocol is to not be too tied to the Nix implementation
itself, allowing it to be used for other builds/workloads in the future.

This means the builder protocol is versatile enough to express the environment a
Nix build expects, while not being aware of "what any of this means".

For example, it is not aware of how certain environment variables are set in a
nix build, but allows specifying environment variables that should be set.

It's also not aware of what nix store paths are. Instead, it allows:

 - specifying a list of paths expected to be produced during the build
 - specifying a list of castore root nodes to be present in a specified
   `inputs_dir`.
 - specifying which paths are write-able during build.

In case all specified paths are produced, and the command specified in
`command_args` succeeds, the build is considered to be successful.

This happens to be sufficient to *also* express how Nix builds works.

Check `build/protos/build.proto` for a detailed description of the individual
fields, and the tests in `glue/src/tvix_build.rs` for some examples.
