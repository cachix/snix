---
title: "Architecture"
slug: architecture
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 31
toc: true
---

Snix is more decoupled than the existing, monolithic Nix implementation.

In practice, we expect to gain several benefits from this, such as:

 * Ability to use different builders
 * Ability to use different store implementations
 * No monopolisation of the implementation, allowing users to replace components
   that they are unhappy with (up to and including the language evaluator)
 * Less hidden intra-dependencies between tools due to explicit RPC/IPC
   boundaries

In addition to many individual backend implementations, Builders and Store
backends also provide a gRPC server and clients, allowing to plug in your own
implementation.
