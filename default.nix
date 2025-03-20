# This file sets up the top-level package set by traversing the package tree
# (see //nix/readTree for details) and constructing a matching attribute set
# tree.

{ nixpkgsBisectPath ? null
, parentTargetMap ? null
, nixpkgsConfig ? { }
, localSystem ? builtins.currentSystem
, crossSystem ? null
, ...
}@args:

let
  readTree = import ./nix/readTree { };

  readDepot = depotArgs: readTree {
    args = depotArgs;
    path = ./.;
    scopedArgs = {
      # FIXME(Lix): this cannot work in Lix itself.
      # __findFile = _: _: throw "Do not import from NIX_PATH in the depot!";
      builtins = builtins // {
        currentSystem = throw "Use localSystem from the readTree args instead of builtins.currentSystem!";
      };
    };
  };

  # To determine build targets, we walk through the depot tree and
  # fetch attributes that were imported by readTree and are buildable.
  #
  # Any build target that contains `meta.ci.skip = true` or is marked
  # broken will be skipped.
  # Is this tree node eligible for build inclusion?
  eligible = node: (node ? outPath) && !(node.meta.ci.skip or (node.meta.broken or false));

in
readTree.fix (self: (readDepot {
  inherit localSystem crossSystem;
  depot = self;

  # Pass third_party as 'pkgs' (for compatibility with external
  # imports for certain subdirectories)
  pkgs = self.third_party.nixpkgs;

  # Expose lib attribute to packages.
  lib = self.third_party.nixpkgs.lib;

  # Pass arguments passed to the entire depot through, for packages
  # that would like to add functionality based on this.
  #
  # Note that it is intended for exceptional circumstance, such as
  # debugging by bisecting nixpkgs.
  externalArgs = args;
}) // {
  # Make the path to the depot available for things that might need it
  # (e.g. NixOS module inclusions)
  path = self.third_party.nixpkgs.lib.cleanSourceWith {
    name = "depot";
    src = ./.;
    filter = self.third_party.nixpkgs.lib.cleanSourceFilter;
  };

  # Additionally targets can be excluded from CI by adding them to the
  # list below.
  ci.excluded = [
  ];

  # List of all buildable targets, for CI purposes.
  #
  # Note: To prevent infinite recursion, this *must* be a nested
  # attribute set (which does not have a __readTree attribute).
  ci.targets = readTree.gather
    (t: (eligible t) && (!builtins.elem t self.ci.excluded))
    (self // {
      # remove the pipelines themselves from the set over which to
      # generate pipelines because that also leads to infinite
      # recursion.
      ops = self.ops // { pipelines = null; };
    });

  # Derivation that gcroots all depot targets.
  ci.gcroot = with self.third_party.nixpkgs; writeText "depot-gcroot"
    (builtins.concatStringsSep "\n"
      (lib.flatten
        (map (p: map (o: p.${o}) p.outputs or [ ]) # list all outputs of each drv
          self.ci.targets)));
})
