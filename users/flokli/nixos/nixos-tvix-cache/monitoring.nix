{ config, ... }:
let
  domain = config.machine.domain;
in
{
  # Configure the NixOS machine with Grafana and Tempo to collect metrics from nar-bridge.

  services.tempo = {
    enable = true;
    settings = {
      auth_enabled = false;
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = 9080;
        grpc_listen_address = "127.0.0.1";
        grpc_listen_port = 9095;
        grpc_server_max_recv_msg_size = 67108864;
        grpc_server_max_send_msg_size = 67108864;
        log_level = "warn";
      };
      distributor.receivers = {
        otlp.protocols = {
          grpc = { }; # *:4317
          http = { }; # *:4318
        };
      };
      storage.trace = {
        backend = "local";
        wal.path = "/var/lib/tempo/wal";
        local.path = "/var/lib/tempo/blocks";
      };
      usage_report.reporting_enabled = false;
    };
  };

  # No need, tempo collects the traces directly.
  #
  # services.opentelemetry-collector = {
  #   enable = true;

  #   settings = {
  #     receivers = {
  #       otlp.protocols.grpc.endpoint = "127.0.0.1:4317";
  #       otlp.protocols.http.endpoint = "127.0.0.1:4318";
  #     };

  #     processors = {
  #       batch = { };
  #     };

  #     exporters = {
  #       otlp = {
  #         endpoint = "127.0.0.1:9080"; # Tempo
  #       };
  #     };

  #     extensions = {
  #       zpages = { };
  #     };

  #     service = {
  #       extensions = [
  #         "zpages"
  #       ];
  #       pipelines = {
  #         traces = {
  #           receivers = [ "otlp" ];
  #           processors = [ "batch" ];
  #           exporters = [ "otlp" ];
  #         };
  #         metrics = {
  #           receivers = [ "otlp" ];
  #           processors = [ "batch" ];
  #           exporters = [ "otlp" ];
  #         };
  #         logs = {
  #           receivers = [ "otlp" ];
  #           processors = [ "batch" ];
  #           exporters = [ "otlp" ];
  #         };
  #       };
  #     };
  #   };
  # };

  services.grafana = {
    enable = true;

    settings = {
      server = {
        domain = domain;
        http_addr = "127.0.0.1";
        http_port = 3000;
        root_url = "https://%(domain)s/grafana";
        serve_from_sub_path = true;
      };
      analytics.reporting_enabled = false;
      "auth.anonymous" = {
        enabled = true;
      };
      auth.disable_login_form = true;
      "auth.basic".enabled = false;
      "auth.github" = {
        enabled = true;
        client_id = "Ov23liAnuBwzWtJJ7gv4";
        client_secret = "$__file{/run/credentials/grafana.service/github_auth_client_secret}";
        scopes = "user:email,read:org";
        auth_url = "https://github.com/login/oauth/authorize";
        token_url = "https://github.com/login/oauth/access_token";
        api_url = "https://api.github.com/user";
        allow_sign_up = true;
        auto_login = false;
        allowed_organizations = [ "numtide" ];
        role_attribute_path = "contains(groups[*], '@numtide/network') && 'GrafanaAdmin' || 'Viewer'";
      };
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Tempo";
          type = "tempo";
          uid = "traces";
          url = "http://127.0.0.1:3200";
          access = "proxy";
          timeout = "300";

          jsonData = {
            nodeGraph.enabled = true;
            # tracesToLogs.datasourceUid = "logs";
            # tracesToMetrics.datasourceUid = "metrics";
            # serviceMap.datasourceUid = "metrics";
            # nodeGraph.enabled = true;
            # lokiSearch.datasourceUid = "logs";
          };
        }
      ];
    };
  };

  systemd.services.grafana.serviceConfig.LoadCredential = "github_auth_client_secret:/etc/secrets/grafana_github_auth_client_secret";

  services.nginx.virtualHosts."${domain}".locations."/grafana" = {
    proxyPass = "http://localhost:3000";
  };
}
