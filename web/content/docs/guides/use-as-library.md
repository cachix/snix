---
title: "Use as a library"
slug: use-as-library
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 13
toc: true
---

If you want to use (parts of) Snix in your own project, you can simply refer to
it using cargo and specifying the git sources. `cargo` will pin the exact rev
in `Cargo.lock`. See [The Cargo Book](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html#specifying-dependencies-from-git-repositories) for details.

We do not publish to crates.io yet, due to the interfaces still being a bit
in flux.

For example, to add `nix-compat`, exposing a lot of Nix data types and formats,
add the following line to your `Cargo.toml`'s `[dependencies]`':


```toml
nix-compat = { git = "https://git.snix.dev/snix/snix.git" }
```


{{<callout>}}
Keep in mind some crates have additional requirements on their environment.

For example, `snix-castore` and `snix-store` need to have access to a `protobuf`
compiler and the proto defintions (setting `PROTO_ROOT` usually).
`tvix-build` wants `TVIX_BUILD_SANDBOX_SHELL` to be set, etc.

Check each crates' `build.rs` scripts for details.
{{</callout>}}
