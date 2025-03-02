{ depot, pkgs, lib, ... }:

let
  # Seed a tvix-store with the specified path, then start a VM with the
  # tvix-boot initrd.
  # Allows customizing the cmdline, which can be used to list files,
  # or specify what init should be booted.
  mkBootTest =
    { blobServiceAddr ? "memory://"
    , directoryServiceAddr ? "memory://"
    , pathInfoServiceAddr ? "memory://"


      # The path to import.
    , path

      # Whether the path should be imported as a closure.
      # If false, importPathName must be specified.
    , isClosure ? false
      # Whether to use nar-bridge to upload, rather than tvix-store copy.
      # using nar-bridge currently is "slower", as the `pkgs.mkBinaryCache` build
      # takes quite some time.
    , useNarBridge ? false

    , importPathName ? null

      # Commands to run before starting the tvix-daemon. Useful to provide
      # auxillary mock services.
    , preStart ? ""

      # The cmdline to pass to the VM.
      # Defaults to tvix.find, which lists all files in the store.
    , vmCmdline ? "tvix.find"
      # The string we expect to find in the VM output.
      # Defaults the value of `path` (the store path we upload).
    , assertVMOutput ? path
    }:

      assert isClosure -> importPathName == null;
      assert (!isClosure) -> importPathName != null;

      pkgs.stdenv.mkDerivation ({
        name = "run-vm";

        nativeBuildInputs = [
          depot.tvix.store
          depot.tvix.boot.runVM
        ] ++ lib.optionals (isClosure && useNarBridge) [
          depot.tvix.nar-bridge
          pkgs.curl
          pkgs.rush-parallel
          pkgs.zstd.bin
          pkgs.nix
        ];
        buildCommand = ''
          set -eou pipefail
          touch $out
          # Ensure we can construct http clients.
          export SSL_CERT_FILE=/dev/null

          ${preStart}

          # Start the tvix daemon, listening on a unix socket.
          BLOB_SERVICE_ADDR=${lib.escapeShellArg blobServiceAddr} \
          DIRECTORY_SERVICE_ADDR=${lib.escapeShellArg directoryServiceAddr} \
          PATH_INFO_SERVICE_ADDR=${lib.escapeShellArg pathInfoServiceAddr} \
            tvix-store \
              --otlp=false \
              daemon -l $PWD/tvix-store.sock &

          # Wait for the service to report healthy.
          timeout 22 sh -c "until ${pkgs.ip2unix}/bin/ip2unix -r out,path=$PWD/tvix-store.sock ${pkgs.grpc-health-check}/bin/grpc-health-check --address 127.0.0.1 --port 8080; do sleep 1; done"

          # Export env vars so that subsequent tvix-store commands will talk to
          # our tvix-store daemon over the unix socket.
          export BLOB_SERVICE_ADDR=grpc+unix://$PWD/tvix-store.sock
          export DIRECTORY_SERVICE_ADDR=grpc+unix://$PWD/tvix-store.sock
          export PATH_INFO_SERVICE_ADDR=grpc+unix://$PWD/tvix-store.sock
        '' + lib.optionalString (!isClosure) ''
          echo "Importing ${path} into tvix-store with name ${importPathName}…"
          cp -R ${path} ${importPathName}
          outpath=$(tvix-store import ${importPathName})

          echo "imported to $outpath"
        '' + lib.optionalString (isClosure && !useNarBridge) ''
          echo "Copying closure ${path}…"
          # This picks up the `closure` key in `$NIX_ATTRS_JSON_FILE` automatically.
          tvix-store --otlp=false copy
        '' + lib.optionalString (isClosure && useNarBridge) ''
          echo "Starting nar-bridge…"
          nar-bridge \
            --otlp=false \
            -l $PWD/nar-bridge.sock &

          # Wait for nar-bridge to report healthy.
          timeout 22 sh -c "until ${pkgs.curl}/bin/curl -s --unix-socket $PWD/nar-bridge.sock http:///nix-binary-cache; do sleep 1; done"

          # Upload. We can't use nix copy --to http://…, as it wants access to the nix db.
          # However, we can use mkBinaryCache to assemble .narinfo and .nar.xz to upload,
          # and then drive a HTTP client ourselves.
          to_upload=${
            pkgs.mkBinaryCache {
              rootPaths = [ path ];
              # Implemented in https://github.com/NixOS/nixpkgs/pull/376365
              compression = "zstd";
            }
          }

          # Upload all NAR files (with some parallelism).
          # As mkBinaryCache produces them xz-compressed, unpack them on the fly.
          # nar-bridge doesn't care about the path we upload *to*, but a
          # subsequent .narinfo upload need to refer to its contents (by narhash).
          echo -e "Uploading NARs… "
          # TODO(flokli): extension of the nar files where changed from .nar.{compression} to .{compression}
          # https://github.com/NixOS/nixpkgs/pull/376365
          ls -d $to_upload/nar/*.zst | rush -n1 'nar_hash=$(zstdcat < {} | nix-hash --base32 --type sha256 --flat /dev/stdin);zstdcat < {} | curl -s --fail-with-body -T - --unix-socket $PWD/nar-bridge.sock http://localhost:9000/nar/''${nar_hash}.nar'
          echo "Done."

          # Upload all NARInfo files.
          # FUTUREWORK: This doesn't upload them in order, and currently relies
          # on PathInfoService not doing any checking.
          # In the future, we might want to make this behaviour configurable,
          # and disable checking here, to keep the logic simple.
          ls -d $to_upload/*.narinfo | rush 'curl -s -T - --unix-socket $PWD/nar-bridge.sock http://localhost:9000/$(basename {}) < {}'
        '' + ''
          # Invoke a VM using tvix as the backing store, ensure the outpath appears in its listing.
          echo "Starting VM…"

          CH_CMDLINE="${vmCmdline}" run-tvix-vm 2>&1 | tee output.txt
          grep "${assertVMOutput}" output.txt
        '';
        requiredSystemFeatures = [ "kvm" ];
        # HACK: The boot tests are sometimes flaky, and we don't want them to
        # periodically fail other build. Have Buildkite auto-retry them 2 times
        # on failure.
        # Logs for individual failures are still available, so it won't hinder
        # flakiness debuggability.
        meta.ci.buildkiteExtraStepArgs = {
          retry.automatic = true;
        };
      } // lib.optionalAttrs (isClosure && !useNarBridge) {
        __structuredAttrs = true;
        exportReferencesGraph.closure = [ path ];
      });

  testSystem = (pkgs.nixos {
    # Set some options necessary to evaluate.
    boot.loader.systemd-boot.enable = true;
    # TODO: figure out how to disable this without causing eval to fail
    fileSystems."/" = {
      device = "/dev/root";
      fsType = "tmpfs";
    };

    services.getty.helpLine = "Onwards and upwards.";
    systemd.services.do-shutdown = {
      after = [ "getty.target" ];
      description = "Shut down again";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = "/run/current-system/sw/bin/systemctl poweroff --when=+10s";
    };

    # Don't warn about stateVersion.
    system.stateVersion = "24.05";

    # Speed-up evaluation and building.
    documentation.enable = lib.mkForce false;
  }).config.system.build.toplevel;

in
depot.nix.readTree.drvTargets {
  docs-memory = (mkBootTest {
    path = ../../docs;
    importPathName = "docs";
  });
  docs-persistent = (mkBootTest {
    blobServiceAddr = "objectstore+file:///build/blobs";
    directoryServiceAddr = "redb:///build/directories.redb";
    pathInfoServiceAddr = "redb:///build/pathinfo.redb";
    path = ../../docs;
    importPathName = "docs";
  });

  closure-tvix = (mkBootTest {
    blobServiceAddr = "objectstore+file:///build/blobs";
    path = depot.tvix.store;
    isClosure = true;
  });

  closure-nixos = (mkBootTest {
    blobServiceAddr = "objectstore+file:///build/blobs";
    pathInfoServiceAddr = "redb:///build/pathinfo.redb";
    directoryServiceAddr = "redb:///build/directories.redb";
    path = testSystem;
    isClosure = true;
    vmCmdline = "init=${testSystem}/init panic=-1"; # reboot immediately on panic
    assertVMOutput = "Onwards and upwards.";
  });

  closure-nixos-bigtable = (mkBootTest {
    blobServiceAddr = "objectstore+file:///build/blobs";
    directoryServiceAddr = "bigtable://instance-1?project_id=project-1&table_name=directories&family_name=cf1";
    pathInfoServiceAddr = "bigtable://instance-1?project_id=project-1&table_name=pathinfos&family_name=cf1";
    path = testSystem;
    useNarBridge = true;
    preStart = ''
      ${pkgs.cbtemulator}/bin/cbtemulator -address $PWD/cbtemulator.sock &
      timeout 22 sh -c 'until [ -e $PWD/cbtemulator.sock ]; do sleep 1; done'

      export BIGTABLE_EMULATOR_HOST=unix://$PWD/cbtemulator.sock
      ${pkgs.google-cloud-bigtable-tool}/bin/cbt -instance instance-1 -project project-1 createtable directories
      ${pkgs.google-cloud-bigtable-tool}/bin/cbt -instance instance-1 -project project-1 createfamily directories cf1
      ${pkgs.google-cloud-bigtable-tool}/bin/cbt -instance instance-1 -project project-1 createtable pathinfos
      ${pkgs.google-cloud-bigtable-tool}/bin/cbt -instance instance-1 -project project-1 createfamily pathinfos cf1
    '';
    isClosure = true;
    vmCmdline = "init=${testSystem}/init panic=-1"; # reboot immediately on panic
    assertVMOutput = "Onwards and upwards.";
  });

  closure-nixos-s3 = (mkBootTest {
    blobServiceAddr = "objectstore+s3://mybucket/blobs?aws_access_key_id=myaccesskey&aws_secret_access_key=supersecret&aws_endpoint_url=http%3A%2F%2Flocalhost%3A9000&aws_allow_http=1";
    # we cannot use s3 here yet without any caching layer, as we don't allow "deeper" access to directories (non-root nodes)
    # directoryServiceAddr = "objectstore+s3://mybucket/directories?aws_access_key_id=myaccesskey&aws_secret_access_key=supersecret&endpoint=http%3A%2F%2Flocalhost%3A9000&aws_allow_http=1";
    directoryServiceAddr = "memory://";
    pathInfoServiceAddr = "memory://";
    path = testSystem;
    useNarBridge = true;
    preStart = ''
      MINIO_ACCESS_KEY=myaccesskey MINIO_SECRET_KEY=supersecret MINIO_ADDRESS=127.0.0.1:9000 ${pkgs.minio}/bin/minio server $(mktemp -d) &
      timeout 22 sh -c 'until ${pkgs.netcat}/bin/nc -z $0 $1; do sleep 1; done' localhost 9000
      mc_config_dir=$(mktemp -d)
      ${pkgs.minio-client}/bin/mc --config-dir $mc_config_dir alias set 'myminio' 'http://127.0.0.1:9000' 'myaccesskey' 'supersecret'
      ${pkgs.minio-client}/bin/mc --config-dir $mc_config_dir mb myminio/mybucket
    '';
    isClosure = true;
    vmCmdline = "init=${testSystem}/init panic=-1"; # reboot immediately on panic
    assertVMOutput = "Onwards and upwards.";
  });

  closure-nixos-nar-bridge = (mkBootTest {
    blobServiceAddr = "objectstore+file:///build/blobs";
    path = testSystem;
    useNarBridge = true;
    isClosure = true;
    vmCmdline = "init=${testSystem}/init panic=-1"; # reboot immediately on panic
    assertVMOutput = "Onwards and upwards.";
  });
}
