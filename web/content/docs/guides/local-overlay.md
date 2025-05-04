---
title: "Use as a lower store with nix"
slug: local-overlay
description: ""
summary: ""
date: 2025-03-21T22:40:33+00:00
lastmod: 2025-03-21T22:40:33+00:00
draft: false
weight: 14
toc: true
---

This document describes how to configure `snix` as the lower layer in your
[Local Overlay] nix store.

### Build required `snix` components

To use this feature you will need to 2 `snix` compontents, for detailed building
instructions see [Building]({{< ref "building" >}}).

```bash
nix-build -A snix.store -A snix.nix-daemon
```

These will provide `snix-store` and `nix-daemon` binaries.

### Run the `snix` daemon

`snix daemon` is the component exposing `castore` and `store` data. By default,
these live inside `/var/lib/snix`, so make sure it's writable for the user
you're executing it with. See `snix-store daemon --help` for customization
options. `/var/lib/snix`, you can run `snix-store daemon --help` for
customization instructions.

You can run the daemon with:

```bash
$(nix-build -A snix.snix-store)/bin/snix-store daemon
```

### Mount the store

To expose the store paths and their contents as a file system, if can be
FUSE-mounted with the following command:

```bash
$(nix-build -A snix.snix-store)/bin/snix-store mount /path/to/mount
```

This mount will talk to the previously invoked daemon.

Note that by default, this mount won't allow listing files and directories at
the root of the store, if you want to enable it, use the `--list-root` flag, but
be careful with it if your store is really large.

### Run `snix` nix-daemon

```bash
$(nix-build -A snix.nix-daemon)/bin/nix-daemon -l /tmp/snix-daemon.sock \
    --unix-listen-unlink
```

This will launch the `snix` nix-daemon listening on a unix domain socket.

Nix will communicate with it to get metadata about store paths.

### Create an overlayfs mount

{{< callout context="caution" title="Caution" icon="outline/alert-triangle" >}}
Depending on your usecase, this might not be appropriate for a physical NixOS
system, replacing `/nix` globally.

In these cases, you want to ensure store paths needed to boot the system are
available on the plain disk.

You most likely want to mount this combined mountpoint elsewhere, and spin up a
separate mount namespace (via `systemd-nspawn`, `bwrap` or similar) exposing it
at `/nix` in there. You have been warned!
{{</callout>}}


Bind mount your real /nix store on the side, so that nix has direct access to
it, this is optional but allows you to have access to your real nix store
without unmounting:

```bash
mount --bind /nix /opt/nix
```

```bash
mount -t overlay overlay \
  -o lowerdir=/path/to/mount \
  -o upperdir=/opt/nix \
  /nix
```

### Configure nix to use the daemon

With all of the above out of the way, we are ready to configure nix. In the
proposed setup we will configure nix-daemon with an overlay store but for the
Nix CLI you can just configure nix with the overlay store.

#### nix-daemon

The daemon can be configured in the following way:

Add the following line to your `/etc/nix.conf`

```
store = local-overlay://?state=/opt/nix/var/nix&upper-layer=/opt/nix/store&check-mount=false&lower-store=unix%3A%2F%2F%2Ftmp%2Fsnix-daemon.sock
```

#### Personal nix config

With the above configuration in your `/etc/nix.conf`, we need to tell nix not to
use it but instead use `store = daemon` so that only the daemon is aware of the
Local Overlay Store.

This can be achieved by either setting the env variable
`NIX_CONFIG='store = daemon` or by adding `store = daemon` to your
`$XDG_CONFIG_HOME/nix.conf` file.

### Profit

With the above setup you should now be able to have nix use Snix castore as its
lower store.

{{< callout context="caution" title="Caution" icon="outline/alert-triangle" >}}
There are some known (and not yet worked-on) performance issues in Snix
castore, which is why the mount is expected to perform slower than the native
file-system. Depending on your workload, this might or might not be an issue.

Check [our Bug tracker][castore-perf-issues] for updates on that topic.

[castore-perf-issues]: https://git.snix.dev/snix/snix/issues?q=&type=all&sort=&labels=14%2c24
{{</callout>}}


[local overlay]: https://nix.dev/manual/nix/2.26/store/types/experimental-local-overlay-store.html
