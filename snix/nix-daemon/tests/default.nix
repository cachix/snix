{ depot
, pkgs
, lib
, ...
}:

let
  mkTest =
    { closure
    , blobServiceAddr ? "objectstore+file:///tmp/blobs"
    , directoryServiceAddr ? "redb:///tmp/directories.redb"
    , pathInfoServiceAddr ? "redb:///tmp/pathinfo.redb"
    , testScript
    , # FUTUREWORK: make overlay setup configurable for non-local-overlay tests?
    }:

    pkgs.vmTools.runInLinuxVM (
      (pkgs.runCommand "test-script"
        {
          nativeBuildInputs = [
            pkgs.util-linux # mount, mountpoint
            depot.third_party.nixpkgs.nixVersions.stable
            depot.snix.store
          ];
          __structuredAttrs = true;
          exportReferencesGraph.closure = [ closure ];
        }
        (
          ''
            touch $out
            # Ensure we can construct http clients.
            export SSL_CERT_FILE=/dev/null

            # Start the snix daemon, listening on a unix socket.
            BLOB_SERVICE_ADDR=${lib.escapeShellArg blobServiceAddr} \
            DIRECTORY_SERVICE_ADDR=${lib.escapeShellArg directoryServiceAddr} \
            PATH_INFO_SERVICE_ADDR=${lib.escapeShellArg pathInfoServiceAddr} \
              snix-store \
                --otlp=false \
                daemon -l $PWD/snix-store.sock &

            # Wait for the service to report healthy.
            timeout 22 sh -c "until ${pkgs.ip2unix}/bin/ip2unix -r out,path=$PWD/snix-store.sock ${pkgs.grpc-health-check}/bin/grpc-health-check --address 127.0.0.1 --port 8080; do sleep 1; done"

            # Export env vars so that subsequent snix-store commands will talk to
            # our snix-store daemon over the unix socket.
            export BLOB_SERVICE_ADDR=grpc+unix://$PWD/snix-store.sock
            export DIRECTORY_SERVICE_ADDR=grpc+unix://$PWD/snix-store.sock
            export PATH_INFO_SERVICE_ADDR=grpc+unix://$PWD/snix-store.sock

            echo "Copying closure ${closure}…"
            # This picks up the `closure` key in `$NIX_ATTRS_JSON_FILE` automatically.
            snix-store --otlp=false copy 2> /dev/null # noisy progress bars

            # Create mountpoints
            # For this test, we overlay a (treated read-only) snix-provided mountpoint
            # with a read-writeable scratch space.
            # It is exposed at /tmp/merged/nix/store.
            mkdir -p /tmp/snix /tmp/scratch /tmp/work /tmp/merged/nix/store

            snix-store --otlp=false mount -l /tmp/snix --allow-other &
            # FUTUREWORK: add snix-store mount "forking to background" option
            timeout 22 sh -c 'until mountpoint -q /tmp/snix; do sleep 0.5; done'

            mount -t overlay overlay -o lowerdir=/tmp/snix -o workdir=/tmp/work -o upperdir=/tmp/scratch /tmp/merged/nix/store

            # Run the Snix nix-daemon
            RUST_LOG=nix_daemon=debug ${depot.snix.nix-daemon}/bin/nix-daemon --otlp=false --unix-listen-unlink --unix-listen-chmod everybody &
            timeout 22 sh -c 'until [ -e /tmp/snix-daemon.sock ]; do sleep 1; done'

            # Run the test script
            ${testScript}
          ''
        )
      ).overrideAttrs
        (_: {
          memSize = 4096;
        })
    );
  closure = pkgs.hello;
  localOverlayStoreConfig = "local-overlay://?root=/tmp/merged&lower-store=unix%3A%2F%2F%2Ftmp%2Fsnix-daemon.sock&lower-store.real%3D%2Ftmp%2Fsnix&upper-layer=/tmp/scratch&check-mount=false";
in
{
  nixstoreQr = (
    mkTest {
      inherit closure;
      testScript = ''
        nix-store -qR ${closure} \
          --store "${localOverlayStoreConfig}" --extra-experimental-features 'local-overlay-store'
      '';
    }
  );
  pathInfo = (
    mkTest {
      inherit closure;
      testScript = ''
        nix path-info --json --closure-size --recursive ${closure} \
          --store "${localOverlayStoreConfig}" --extra-experimental-features 'local-overlay-store nix-command'
      '';
    }
  );
  /*
    This currently cannot work as our store is not mounted at /nix/store but at another location, and since nix-shell
    needs bash it fails with `unable to exec /nix/store/xxx-bash/bin/bash`, to run shell we need to chroot to have the
    overlay store at /nix/store.
  */
  shell = (
    mkTest {
      inherit closure;
      testScript = ''
        nix shell ${pkgs.hello} \
          --store "${localOverlayStoreConfig}" --extra-experimental-features 'local-overlay-store nix-command'
      '';
    }
  );

  meta.ci.targets = [ "nixstoreQr" "pathInfo" ];
}
