{
  config,
  lib,
  ...
}:
let
  cfg = config.services.depot.loki;
  inherit (lib) mkEnableOption mkIf;
in
{
  options.services.depot.loki.enable = mkEnableOption "Loki storage";

  config = mkIf cfg.enable {
    services.loki = {
      enable = true;
      extraFlags = [ "--config.expand-env" ];

      configuration = {
        server = {
          http_listen_port = 9090;
          grpc_listen_port = 9096;

          # 16M
          grpc_server_max_recv_msg_size = 16777216;
          grpc_server_max_send_msg_size = 16777216;
        };

        auth_enabled = false;

        common = {
          storage.s3 = {
            endpoint = "fsn1.your-objectstorage.com";
            region = "fsn1";
            bucketnames = "snix-loki";
            secret_access_key = "\${S3_KEY}"; # This is a secret injected via an environment variable
            access_key_id = "\${S3_KEY_ID}";
            s3forcepathstyle = true;
          };
          ring = {
            kvstore.store = "memberlist";
            # TODO: Such a ugly hack.
            instance_interface_names = [
              "enp1s0"
              "lo"
            ];
          };
          replication_factor = 1;
        };
        # TODO: Such a ugly hack.
        frontend.instance_enable_ipv6 = true;
        frontend.instance_interface_names = [
          "enp1s0"
          "lo"
        ];

        memberlist = {
          advertise_addr = "127.0.0.1";
          cluster_label = "snix";
          bind_port = 7947;
          advertise_port = 7947;
        };

        storage_config.tsdb_shipper = {
          active_index_directory = "/var/lib/loki/index";
          cache_location = "/var/lib/loki/cache";
        };

        compactor = {
          working_directory = "/var/lib/loki/compactor";
          compaction_interval = "10m";
          retention_enabled = true;
          retention_delete_delay = "1s";
          retention_delete_worker_count = 150;
          delete_request_store = "filesystem";
        };

        limits_config.retention_period = "1w";

        schema_config = {
          configs = [
            {
              from = "2024-07-01";
              store = "tsdb";
              object_store = "s3";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };
      };
    };

    systemd.services.loki.serviceConfig.EnvironmentFile = [ config.age.secrets.loki-environment.path ];

    infra.monitoring.alloy.exporters.loki.port = 9090;
  };
}
