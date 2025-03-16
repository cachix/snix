---
title: "Reference Scanning"
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-14T14:14:35+01:00
draft: false
weight: 45
toc: true
---

At the end of a build, Nix does scan a store path for references to other store
paths (*out of the set of all store paths present during the build*).
It does do this by (only) looking for a list of nixbase32-encoded hashes in
filenames (?), symlink targets and blob contents.

As outlined in the [Builder Protocol]({{< relref "protocol" >}}) page, we
don't want to introduce Nix specifics to the builder protocol, but if we simply
do refscanning on the coordinator side, that side would need to download the
produced inputs and scan them locally.

This is undesireable, as the builder already has all produced
outputs locally, and it'd make more sense for it do do it.

Instead, we want to describe reference scanning in a generic, non-Nix-specific
fashion.

## Proposal

One way to do this is to add an additional field `refscan_needles` to the
`BuildRequest` message.
If this is an non-empty list, all `outputs` are scanned for these.

The `Build` response message would then be extended with an `outputs_needles`
field, containing the same number of elements as the existing `outputs` field,
describing which `refscan_needles` are found for each output.

If there's needles found, they will be a list of indexes into the
`refscan_needles` field specified in the `BuildRequest` field.

For Nix, `refscan_needles` would be populated with the nixbase32 hash parts of
every input store path and output store path. The latter is necessary to scan
for references between multi-output derivations.

This is sufficient to construct the referred store paths in each build output on
the build client.
