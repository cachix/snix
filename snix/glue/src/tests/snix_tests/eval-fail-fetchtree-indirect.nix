(assertTimestamps (builtins.fetchTree {
  type = "indirect";
  id = "nixpkgs";
}))
