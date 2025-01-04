{ depot, pkgs, lib, ... }:

pkgs.haskellPackages.mkDerivation {
  pname = "my-prelude";
  version = "0.0.1-unreleased";

  src = depot.users.Profpatsch.exactSource ./. [
    ./my-prelude.cabal
    ./src/Aeson.hs
    ./src/Comparison.hs
    ./src/Debug.hs
    ./src/Json.hs
    ./src/Json/Enc.hs
    ./src/Arg.hs
    ./src/AtLeast.hs
    ./src/MyPrelude.hs
    ./src/Test.hs
    ./src/Parse.hs
    ./src/Pretty.hs
    ./src/Seconds.hs
    ./src/Tool.hs
    ./src/ValidationParseT.hs
    ./src/Postgres/Decoder.hs
    ./src/Postgres/MonadPostgres.hs
  ];

  isLibrary = true;

  libraryHaskellDepends = [
    pkgs.haskellPackages.pa-prelude
    pkgs.haskellPackages.pa-label
    pkgs.haskellPackages.pa-error-tree
    pkgs.haskellPackages.pa-json
    pkgs.haskellPackages.pa-pretty
    pkgs.haskellPackages.pa-field-parser
    pkgs.haskellPackages.aeson-better-errors
    pkgs.haskellPackages.foldl
    pkgs.haskellPackages.resource-pool
    pkgs.haskellPackages.error
    pkgs.haskellPackages.hs-opentelemetry-api
    pkgs.haskellPackages.hspec
    pkgs.haskellPackages.hspec-expectations-pretty-diff
    pkgs.haskellPackages.monad-logger
    pkgs.haskellPackages.postgresql-simple
    pkgs.haskellPackages.profunctors
    pkgs.haskellPackages.PyF
    pkgs.haskellPackages.semigroupoids
    pkgs.haskellPackages.these
    pkgs.haskellPackages.unliftio
    pkgs.haskellPackages.validation-selective
    pkgs.haskellPackages.vector
  ];

  license = lib.licenses.mit;

}
