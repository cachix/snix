builderball
===========

*A friendly game between Nix caches.*

Builderball acts as a Nix cache to Nix clients, but behind the scenes it
connects to a set of caches and redirects the client to the first available
cache for each `narinfo`.

There are two primary use-cases for this:

1. Fronting multiple different Nix caches (e.g. for round-robin load balancing,
   or to serve multiple separate caches at one address).

2. Distributing artifacts between multiple active Nix builders that connect to
   each other to find already built artifacts.

Builderball is tested with caches backed by
[Harmonia](https://github.com/nix-community/harmonia), but other caches (the
upstream binary cache, Cachix, etc.) should also work fine.

TVL uses Builderball to have builders dynamically join the CI pool and
distribute intermediate outputs between each other. It does not, however,
concern itself with preventing concurrent builds of the same output.

Builderball supports tag-based discovery of Nix caches on Tailscale networks.
TVL runs a [Headscale](https://headscale.net/) network for this purpose.

## Requirements

Builderball should run anywhere that Go can produce working binaries. It does,
however, impose several restrictions in order for the configuration to be valid:

* All clients that can reach Builderball **must** be able to reach all
  caches that it connects to under the **same** addresses.

  Builderball works by rewriting the first discovered `narinfo` for a given
  store path, replacing its NAR URL with an absolute URL pointing towards the
  address of that cache. If a client can connect to Builderball, but not to the
  cache, it might end up receiving a `narinfo` with an unreachable URL.

* *Either* all caches must respond correctly to the default `Host` header set
  when using the addresses configured in/discovered by Builderball, *or* all
  caches must respond to the **same** `Host` header configured with the
  `-cache-host` flag.

* All discovered caches **must** listen on the same port, configured by the
  `-cache-port` flag. This restriction does not apply to statically configured
  caches.


## Usage

```
Usage of ./builderball:

  -cache value
    	Upstream cache URL (can be specified multiple times)
  -cache-host string
    	Host header to send to each binary cache
  -cache-port int
    	port at which to connect to binary cache on each node (default 80)
  -debug
    	whether debug logging should be enabled
  -json
    	whether logging should be in JSON format
  -host string
    	host on which to listen for incoming requests (default "localhost")
  -port int
    	port on which to listen for incoming requests (default 2243)
  -priority int
    	Nix cache priority with which to serve clients (default 50)
  -tailscale
    	whether caches should be discovered on Tailscale
  -tailscale-tag string
    	Tailscale tag to use for discovery (default "tag:nix-cache")
  -ticker int
    	interval in seconds between statistics tickers (default 5)
```
