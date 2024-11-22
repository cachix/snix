{ config, pkgs, ... }:
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

      # move the otlp listener to another port than 4317, and disable the 4318 one.
      # opentelemetry-connector binds on both 4317 and 4318.
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "127.0.0.1:4319";
      };

      storage.trace = {
        backend = "local";
        wal.path = "/var/lib/tempo/wal";
        local.path = "/var/lib/tempo/blocks";
      };
      usage_report.reporting_enabled = false;
    };
  };

  services.alloy.enable = true;

  environment.etc."alloy/config.alloy".text = ''
    prometheus.exporter.unix "main" { }

    prometheus.scrape "main" {
      targets    = prometheus.exporter.unix.main.targets
      forward_to = [otelcol.receiver.prometheus.default.receiver]
    }

    otelcol.receiver.prometheus "default" {
      output {
        metrics = [otelcol.exporter.otlp.default.input]
      }
    }

    otelcol.exporter.otlp "default" {
      client {
        endpoint = "127.0.0.1:4317"
        tls {
          insecure = true
        }
      }
    }
  '';

  services.opentelemetry-collector = {
    enable = true;
    settings = {
      receivers = {
        otlp.protocols.grpc.endpoint = "127.0.0.1:4317";
        otlp.protocols.http.endpoint = "127.0.0.1:4318";
      };

      processors = {
        batch = { };
      };

      exporters = {
        otlp = {
          endpoint = "127.0.0.1:4319"; # Tempo otlp-grpc
          tls.insecure = true;
        };
        "otlphttp/metrics" = {
          compression = "gzip";
          encoding = "proto";
          endpoint = "http://localhost:8428/opentelemetry";
          tls.insecure = true;

        };
      };

      service = {
        pipelines = {
          traces = {
            receivers = [ "otlp" ];
            processors = [ "batch" ];
            exporters = [ "otlp" ];
          };
          metrics = {
            receivers = [ "otlp" ];
            processors = [ "batch" ];
            exporters = [ "otlphttp/metrics" ];
          };
        };
      };
    };
  };

  services.victoriametrics.enable = true;


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
          url = "http://127.0.0.1:9080";
          access = "proxy";
          timeout = "300";

          jsonData = {
            nodeGraph.enabled = true;
            # tracesToLogs.datasourceUid = "logs";
            tracesToMetrics.datasourceUid = "metrics";
            # serviceMap.datasourceUid = "metrics";
            # nodeGraph.enabled = true;
            # lokiSearch.datasourceUid = "logs";
          };
        }
        {
          name = "prometheus";
          type = "prometheus";
          uid = "metrics";
          url = "http://localhost:8428/";
        }
      ];
    };
  };

  systemd.services.grafana.serviceConfig.LoadCredential = "github_auth_client_secret:/etc/secrets/grafana_github_auth_client_secret";

  services.nginx.virtualHosts."${domain}".locations."/grafana" = {
    proxyPass = "http://localhost:3000";
    proxyWebsockets = true;
  };
}
