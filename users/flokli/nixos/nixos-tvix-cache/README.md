# nixos-tvix-cache

This is a fetch-through mirror of cache.nixos.org, hosted by NumTide.

The current machine is a SX65 Hetzner dedicated server with 4x22TB SATA disks,
and 2x1TB NVMe disks.

The goals of this machine:

 - Exercise tvix-store and nar-bridge code
 - Collect usage metrics (see [Grafana](https://nixos.tvix.store/grafana))
 - Identify bottlenecks in the current implementations and fix them
 - Replace cache.nixos.org?

You can configure this as a Nix substitutor on your systems like this:

```nix
  nix.settings.substituters = lib.mkForce [
    "https://nixos.tvix.store"
  ];
```

For store paths it hasn't already seen yet, it'll internally ingest its contents
into tvix-castore (deduplicating in doing so).

Requests for NARs will dynamically reassemble the NAR representation on demand.

Metadata and signatures are preserved (which is why you don't need to add
additional trusted keys).
We need to produce the same data bit by bit, else the signature check in your
Nix/Lix client would fail.

Be however aware that there's zero availability guarantees.
We will frequently redeploy this box, and it might become unavailable without
prior notice.

Tvix currently doesn't have garbage collection. If we run out of disk space, we
might either move things to a bigger box or delete everything on it so far.

As it's only a cache, it should however re-ingest things again.
