{
  depot,
  pkgs,
  lib,
  ...
}:

(depot.snix.crates.workspaceMembers.snix-cli.build.override {
  runTests = true;
  testPreRun = ''
    export SSL_CERT_FILE=/dev/null
  '';
}).overrideAttrs
  (
    finalAttrs: previousAttrs:

    let
      snix-cli = finalAttrs.finalPackage;

      benchmark-gnutime-format-string =
        description:
        "Benchmark: "
        + (builtins.toJSON {
          "${description}" = {
            kbytes = "%M";
            system = "%S";
            user = "%U";
          };
        });

      # You can run the benchmark with a simple `nix run`, like:
      #
      #  nix-build -A snix.cli.meta.ci.extraSteps.benchmark-nixpkgs-cross-hello-outpath
      #
      # TODO(amjoseph): store these results someplace more durable, like git trailers
      #
      mkExprBenchmark =
        { expr, description }:
        let
          name = "snix-cli-benchmark-${description}";
        in
        (pkgs.runCommand name { } ''
          export SSL_CERT_FILE=/dev/null
          ${lib.escapeShellArgs [
            "${pkgs.time}/bin/time"
            "--format"
            "${benchmark-gnutime-format-string description}"
            "${snix-cli}/bin/snix"
            "--no-warnings"
            "-E"
            expr
          ]}
          touch $out
        '');

      mkNixpkgsBenchmark =
        attrpath:
        mkExprBenchmark {
          description = builtins.replaceStrings [ ".drv" ] [ "-drv" ] attrpath;
          expr = "(import ${pkgs.path} {}).${attrpath}";
        };

      # Constructs a Derivation invoking snix-cli inside a build, ensures the
      # calculated snix output path matches what's passed in externally.
      mkNixpkgsEvalTest =
        {
          attrPath ? null, # An attribute that must already be accessible from `pkgs`. Should evaluate to a store path.
          expr ? null, # A Nix expression that should evaluate to a store path.
          expectedPath, # The expected store path that should match one of the above.
        }:
        assert lib.assertMsg (attrPath != null || expr != null) "Either 'attrPath' or 'expr' must be set.";
        let
          name = "snix-eval-test-${
            builtins.replaceStrings [ ".drv" ] [ "-drv" ] (if expr != null then "custom-expr" else attrPath)
          }";
        in
        (pkgs.runCommand name { } ''
          export SSL_CERT_FILE=/dev/null
          SNIX_OUTPUT=$(${snix-cli}/bin/snix --no-warnings -E '${
            if expr != null then expr else "(import ${pkgs.path} {}).${attrPath}"
          }')
          EXPECTED='${
            # the verbatim expected Snix output:
            "=> \"${builtins.unsafeDiscardStringContext expectedPath}\" :: string"
          }'

          echo "Snix output: ''${SNIX_OUTPUT}"
          if [ "$SNIX_OUTPUT" != "$EXPECTED" ]; then
            echo "Correct would have been ''${EXPECTED}"
            exit 1
          fi

          echo "Output was correct."
          touch $out
        '');

      benchmarks = {
        benchmark-hello = (mkNixpkgsBenchmark "hello.outPath");
        benchmark-cross-hello = (mkNixpkgsBenchmark "pkgsCross.aarch64-multiplatform.hello.outPath");
        benchmark-firefox = (mkNixpkgsBenchmark "firefox.outPath");
        benchmark-cross-firefox = (mkNixpkgsBenchmark "pkgsCross.aarch64-multiplatform.firefox.outPath");
        # Example used for benchmarking LightSpan::Delayed in commit bf286a54bc2ac5eeb78c3d5c5ae66e9af24d74d4
        benchmark-nixpkgs-attrnames = (
          mkExprBenchmark {
            expr = "builtins.length (builtins.attrNames (import ${pkgs.path} {}))";
            description = "nixpkgs-attrnames";
          }
        );
      };

      evalTests = {
        eval-nixpkgs-stdenv-drvpath = (
          mkNixpkgsEvalTest {
            attrPath = "stdenv.drvPath";
            expectedPath = pkgs.stdenv.drvPath;
          }
        );
        eval-nixpkgs-stdenv-outpath = (
          mkNixpkgsEvalTest {
            attrPath = "stdenv.outPath";
            expectedPath = pkgs.stdenv.outPath;
          }
        );
        eval-nixpkgs-hello-outpath = (
          mkNixpkgsEvalTest {
            attrPath = "hello.outPath";
            expectedPath = pkgs.hello.outPath;
          }
        );
        eval-nixpkgs-firefox-outpath = (
          mkNixpkgsEvalTest {
            attrPath = "firefox.outPath";
            expectedPath = pkgs.firefox.outPath;
          }
        );
        eval-nixpkgs-firefox-drvpath = (
          mkNixpkgsEvalTest {
            attrPath = "firefox.drvPath";
            expectedPath = pkgs.firefox.drvPath;
          }
        );
        eval-nixpkgs-cross-stdenv-outpath = (
          mkNixpkgsEvalTest {
            attrPath = "pkgsCross.aarch64-multiplatform.stdenv.outPath";
            expectedPath = pkgs.pkgsCross.aarch64-multiplatform.stdenv.outPath;
          }
        );
        eval-nixpkgs-cross-hello-outpath = (
          mkNixpkgsEvalTest {
            attrPath = "pkgsCross.aarch64-multiplatform.hello.outPath";
            expectedPath = pkgs.pkgsCross.aarch64-multiplatform.hello.outPath;
          }
        );
        # FIXME: nixpkgs changed and the output path differs now
        # eval-nixpkgs-nixos-graphical-installer-drvpath = (
        #   mkNixpkgsEvalTest {
        #     expr = "(import ${pkgs.path}/nixos/release.nix { }).iso_graphical.${pkgs.system}.drvPath";
        #     expectedPath = (import "${pkgs.path}/nixos/release.nix" { }).iso_graphical.${pkgs.system}.drvPath;
        #   }
        # );
        # eval-nixpkgs-nixos-graphical-installer-outpath = (
        #   mkNixpkgsEvalTest {
        #     expr = "(import ${pkgs.path}/nixos/release.nix { }).iso_graphical.${pkgs.system}.outPath";
        #     expectedPath = (import "${pkgs.path}/nixos/release.nix" { }).iso_graphical.${pkgs.system}.outPath;
        #   }
        # );
      };
    in
    {
      meta = {
        ci.targets = (builtins.attrNames benchmarks) ++ (builtins.attrNames evalTests);
      };

      # Expose benchmarks and evalTests as standard CI targets.
      passthru = previousAttrs.passthru // benchmarks // evalTests;
    }
  )
