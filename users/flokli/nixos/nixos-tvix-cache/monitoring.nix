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
      # 10x the default
      overrides.defaults.ingestion.max_traces_per_user = 10000 * 10;
    };
  };

  services.alloy.enable = true;

  environment.etc."alloy/config.alloy".text = ''
    // Accept OTLP. Forward metrics to mimir, and traces to tempo.
    otelcol.receiver.otlp "main" {
      grpc {
        endpoint = "[::1]:4317"
      }

      http {
        endpoint = "[::1]:4318"
      }

      output {
        metrics = [otelcol.exporter.otlphttp.mimir.input]
        traces = [otelcol.exporter.otlp.tempo.input]
      }
    }

    // We push to Tempo over otlp-grpc.
    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "127.0.0.1:4319"
        tls {
          insecure = true
        }
      }
    }

    // We push to Mimir over otlp-http.
    otelcol.exporter.otlphttp "mimir" {
      client {
        endpoint = "http://localhost:9009/otlp"
      }
    }

    // Run a bundled node-exporter.
    prometheus.exporter.unix "main" { }

    // Scrape it.
    prometheus.scrape "main" {
      targets    = prometheus.exporter.unix.main.targets
      forward_to = [otelcol.receiver.prometheus.default.receiver]
    }

    // Convert Prometheus metrics to OTLP and export them.
    otelcol.receiver.prometheus "default" {
      output {
        metrics = [otelcol.exporter.otlphttp.mimir.input]
      }
    }
  '';

  services.mimir.enable = true;
  services.mimir.configuration = {
    server.grpc_listen_address = "127.0.0.1";
    server.grpc_listen_port = 9096; # default 9095 conflicts with tempo
    server.http_listen_address = "127.0.0.1";
    server.http_listen_port = 9009;

    multitenancy_enabled = false;

    # https://github.com/grafana/mimir/discussions/8773
    compactor.sharding_ring.instance_addr = "127.0.0.1";
    distributor.ring.instance_addr = "127.0.0.1";
    store_gateway.sharding_ring.instance_addr = "127.0.0.1";
    ingester.ring.instance_addr = "127.0.0.1";
    ingester.ring.replication_factor = 1;

    memberlist.advertise_addr = "127.0.0.1";
  };

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
          name = "mimir";
          type = "prometheus";
          uid = "mimir";
          url = "http://localhost:9009/prometheus";
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
