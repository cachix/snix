# Tvix - Architecture & data flow

## Background

We intend for Tvix tooling to be more decoupled than the existing,
monolithic Nix implementation. In practice, we expect to gain several
benefits from this, such as:

- Ability to use different builders
- Ability to use different store implementations
- No monopolisation of the implementation, allowing users to replace
  components that they are unhappy with (up to and including the
  language evaluator)
- Less hidden intra-dependencies between tools due to explicit RPC/IPC
  boundaries

Communication between different components of the system will use
gRPC. The rest of this document outlines the components.

## Components

### Coordinator

```admonish warning
Currently there's no separate coordinator. Most of the interaction between
store, builder and evaluator is done by library code living in the `tvix-glue`
crate (and `tvix-cli` is a user of it).

Keep in mind some of the statements below are outdated and neither reflect
reality nor desired design anymore.
```

*Purpose:* The coordinator (in the simplest case, the Tvix CLI tool)
oversees the flow of a build process and delegates tasks to the right
subcomponents. For example, if a user runs the equivalent of
`nix-build` in a folder containing a `default.nix` file, the
coordinator will invoke the evaluator, pass the resulting derivations
to the builder and coordinate any necessary store interactions (for
substitution and other purposes).

While many users are likely to use the CLI tool as their primary
method of interacting with Tvix, it is not unlikely that alternative
coordinators (e.g. for a distributed, "Nix-native" CI system) would be
implemented. To facilitate this, we are considering implementing the
coordinator on top of a state-machine model that would make it
possible to reuse the FSM logic without tying it to any particular
kind of application.

### Store

*Purpose:* Store takes care of storing build results. It provides a
unified interface to get store paths and upload new ones, as well as querying
for the existence of a store path and its metadata (references, signatures, …).

Tvix natively uses an improved store protocol. Instead of transferring around
NAR files, which don't provide an index and don't allow seekable access, a
concept similar to git tree hashing is used.

This allows more granular substitution, chunk reusage and parallel download of
individual files, reducing bandwidth usage.
As these chunks are content-addressed, it opens up the potential for
peer-to-peer trustless substitution of most of the data, as long as we sign the
root of the index.

Tvix still keeps the old-style signatures, NAR hashes and NAR size around. In
the case of NAR hash / NAR size, this data is strictly required in some cases.
The old-style signatures are valuable for communication with existing
implementations.

Old-style binary caches (like cache.nixos.org) can still be exposed via the new
interface, by doing on-the-fly (re)chunking/ingestion.

Most likely, there will be multiple implementations of store, some storing
things locally, some exposing a "remote view".

A few possible ones that come to mind are:

- Local store
- SFTP/ GCP / S3 / HTTP
- NAR/NARInfo protocol: HTTP, S3

A remote Tvix store can be connected by simply connecting to its gRPC
interface, possibly using SSH tunneling, but there doesn't need to be an
additional "wire format" like the Nix `ssh(+ng)://` protocol.

Settling on one interface allows composition of stores, meaning it becomes
possible to express substitution from remote caches as a proxy layer.

It'd also be possible to write a FUSE implementation on top of the RPC
interface, exposing a lazily-substituting /nix/store mountpoint. Using this in
remote build context dramatically reduces the amount of data transferred to a
builder, as only the files really accessed during the build are substituted.
