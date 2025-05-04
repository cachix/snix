# TODO

This contains a rough collection of ideas on the TODO list, trying to keep track
of it somewhere.

It's in process of being migrated to the
[Issue Tracker](https://git.snix.dev/snix/snix/issues) and documentation.
Please add future ideas to the issue tracker only.

Before picking something from there to work on, ask in `#snix` to make
sure noone is working on this, or has some specific design in mind already.

## Correctness > Performance
A lot of the Nix behaviour isn't well documented out, and before going too deep
into performance optimizations, we need to ensure we properly grasped all hidden
features. This is to avoid doing a lot of "overall architecture perf-related
work" and increased code complexity based on a mental model that might get
disproved later on, as we work towards correctness.

We do this by evaluating more and more parts of the official Nix test suite, as
well as our own Tvix test suite, and compare it with Nix' output.

Additionally, we evaluate attributes from nixpkgs, compare calculated output
paths (to determine equivalence of evaluated A-Terms) and fix differences as we
encounter them.

This currently is a very manual and time-consuming process, both in terms of
setup, as well as spotting the source of the differences (and "compensating" for
the resulting diff noise on resulting mismtaches).

 - We could use some better tooling that periodically evaluates nixpkgs, and
   compares the output paths with the ones produced by Nix
 - We could use some better tooling that can spot the (real) differences between
   two (graphs of) derivations, while removing all resulting noise from the diff
in resulting store paths.


## Error cleanup
 - Currently, all services use snix_castore::Error, which only has two kinds
   (invalid request, storage error), containing an (owned) string.
   This is quite primitive. We should have individual error types for BS, DS, PS.
   Maybe these should have some generics to still be able to carry errors from
   the underlying backend, similar to `IngestionError`.
   There was an attempt to give PS separate error types (cl/11695), but this
   ended up very verbose.
   Every error had to be boxed, and a possible additional message be added. Some
   errors that didn't wrap another underlying errors were hard to construct, too
   (requiring the addition of errors). All of this without even having added
   proper backtrace support, which would be quite helpful in store hierarchies.
   `anyhow`'s `.context()` gives us most of this out of the box. Maybe we can
   use that, using enums rather than `&'static str` as context in some cases?

## Documentation
Extend the other pages in here. Some ideas on what should be tackled:
 - Document what Tvix is, and what it is not yet. What it is now, what it is not
   (yet), explaining some of the architectural choices (castore, more hermetic
   `Build` repr), while still being compatible. Explain how it's possible to
   plug in other frontends, and use `tvix-{[ca]store,build}` without Nixlang even.
   And how `nix-compat` is a useful crate for all sorts of formats and data
   types of Nix.
 - Update the Architecture diagram to model the current state of things.
   There's no gRPC between Coordinator and Evaluator.
 - Add a dedicated section/page explaining the separation between tvix-glue and
   tvix-eval, and how more annoying builtins get injected into tvix-eval through
   tvix-glue.
   Maybe restructure to only explain the component structure potentially
   crossing process boundaries (those with gRPC), and make the rest more crate
   and trait-focused?
 - Restructure docs on castore vs store, this seems to be duplicated a bit and
   is probably still not too clear.
 - Absorb the rest of //snix/website into this.

### Derivation -> Build
While we have some support for `structuredAttrs` and `fetchClosure` (at least
enough to calculate output hashes, aka produce identical ATerm), the code
populating the `Build` struct doesn't exist it yet.

Similarly, we also don't properly populate the build environment for
`fetchClosure` yet. (Note there already is `ExportedPathInfo`, so once
`structuredAttrs` is there this should be easy.

### Builders
Once builds are proven to work with real-world builds, and the corner cases
there are ruled out, adding other types of builders might be interesting.

 - bwrap
 - gVisor
 - Cloud Hypervisor (using similar technique as `//snix//boot`).

Long-term, we want to extend traits and gRPC protocol.
This requires some more designing. Some goals:

 - (more granular) control while a build is happening
 - expose more telemetry and logs

 - Add pre-flight checks in the OCI builder:
   - ensure `fusermount` suid binary exists
   - ensure `allow_other` is set
   - ensure `runc` exists in `$PATH`


### Store composition
 - Combinators: list-by-priority, first-come-first-serve, cache
 - Store composition hierarchies (@yuka).
   - URL format too one-dimensional.
   - We want to have nice and simple user-facing substituter config, including
     sensible default wrappers for caching, retries, fallbacks, as well as
     granular control for power-users.
   - Current design idea:
     - Have a concept similar to rclone config (map with store aliases as
       keys, allowing to refer to stores by their alias from other parts of
       the config).
       It allows both referring to by name, as well as ad-hoc definition:
       https://rclone.org/docs/#syntax-of-remote-paths
     - Each store needs to be aware of its "instance name", so it can be
       included in logs, metrics, …
     - Have a "instantiation function" traversing such a config data structure,
       creating store instances and plugging them together, ultimately returning
       a dyn …Service interface.
     - No reconfiguration/reconcilation for now
     - Making URLs the primary data format would get ugly quite easily (hello
       multiple layers of escaping!), so best to convert the existing URL
       syntax to our new config format on the fly and then use one codepath
       to instantiate/assemble. Similarly, something like the "user-facing
       substituter config" mentioned above could aalso be converted to such a
       config format under the hood.
     - Maybe add a ?cache=$other_url parameter support to the URL syntax, to
       easily wrap a store with a caching frontend, using $other_url as the
      "near" store URL.

### Store Config
 - We might also have common options global over all backends, like chunking
   parameters for chunking blobservices. Think where this would fit in.
 - Rework the URL syntax for object_store. We should support the default s3/gcs
   URLs at least.

### O11Y
 - Trace propagation for object_store once they support a way to register a
   middleware, so we can use that to register a tracing middleware.
   https://github.com/apache/arrow-rs/issues/5990
