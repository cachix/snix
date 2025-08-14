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
      # bump defaults
      overrides.defaults.ingestion.max_traces_per_user = 10000 * 10;
      overrides.defaults.global.max_bytes_per_trace = 500 * 1000 * 1000;
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
      scrape_interval = "15s"
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
        protocol = "socket";
        socket = "/run/grafana/web.sock";
        socket_gid = config.ids.gids.nginx;
        domain = domain;
        root_url = "https://%(domain)s/grafana";
        serve_from_sub_path = true;
      };
      analytics.reporting_enabled = false;
      "auth.anonymous" = {
        enabled = true;
        org_role = "Viewer";
      };
      auth.disable_login_form = true;
      "auth.basic".enabled = false;
      "auth.generic_oauth" = {
        enabled = true;

        name = "snix SSO";
        client_id = "nb_grafana";
        client_secret = "$__file{/run/credentials/grafana.service/keycloak_auth_client_secret}";

        auth_url = "https://auth.snix.dev/realms/snix-project/protocol/openid-connect/auth";
        token_url = "https://auth.snix.dev/realms/snix-project/protocol/openid-connect/token";
        api_url = "https://auth.snix.dev/realms/snix-project/protocol/openid-connect/userinfo";

        login_attribute_path = "username";
        email_attribute_path = "email";
        name_attribute_path = "full_name";

        scopes = [
          "openid"
          "profile"
          "email"
        ];

        allow_sign_up = true;
        auto_login = true;

        allow_assign_grafana_admin = true;
        role_attribute_path = "contains(nb_grafana_roles[*], 'Admin') && 'Admin' || contains(nb_grafana_roles[*], 'Editor') && 'Editor' || 'Viewer'";
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
          jsonData = {
            timeInterval = "15s";
          };
        }
      ];
    };
  };

  # TODO: migrate to agenix
  systemd.services.grafana.serviceConfig.LoadCredential = [
    "github_auth_client_secret:/etc/secrets/grafana_github_auth_client_secret"
    "keycloak_auth_client_secret:/etc/secrets/keycloak_auth_client_secret"
  ];
  systemd.services.grafana.serviceConfig.RuntimeDirectory = "grafana";
  systemd.services.grafana.serviceConfig.SupplementaryGroups = "nginx";

  services.nginx.upstreams.grafana.servers."unix:/run/grafana/web.sock" = { };
  services.nginx.virtualHosts."${domain}".locations."/grafana" = {
    proxyPass = "http://grafana";
    proxyWebsockets = true;
  };
}
