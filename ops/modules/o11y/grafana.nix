{ depot
, config
, lib
, ...
}:
let
  cfg = config.services.depot.grafana;
  inherit (lib) mkEnableOption mkIf;
in
{
  options.services.depot.grafana.enable = mkEnableOption "Grafana frontend";

  config = mkIf cfg.enable {
    services = {
      grafana = {
        enable = true;

        settings = {
          server = {
            domain = "status.snix.dev";
            http_addr = "127.0.0.1";
            http_port = 2342;
            root_url = "https://status.snix.dev/";
          };

          database = {
            type = "postgres";
            user = "grafana";
            host = "/run/postgresql";
          };

          "auth.anonymous" = {
            enabled = true;
            org_role = "Viewer";
          };

          "auth.generic_oauth" = {
            enabled = true;

            name = "snix SSO";
            client_id = "grafana";
            client_secret = "$__file{${config.age.secrets.grafana-oauth-secret.path}}";

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
              "offline_access"
              "roles"
            ];

            allow_sign_up = true;
            auto_login = true;
            allow_assign_grafana_admin = true;

            role_attribute_path = "contains(grafana_roles[*], 'Admin') && 'GrafanaAdmin' || contains(grafana_roles[*], 'Editor') && 'Editor' || 'Viewer'";
          };

          dashboards.default_home_dashboard_path = "${depot.ops.dashboards.node_exporter}";

          feature_toggles.enable = "autoMigrateOldPanels newVizTooltips";
          security.angular_support_enabled = false;
        };

        provision = {
          dashboards.settings = {
            apiVersion = 1;
            providers = [
              {
                name = "default";
                options.path = depot.ops.dashboards.all;
              }
            ];
          };

          datasources.settings = {
            apiVersion = 1;
            datasources = [
              {
                name = "Mimir";
                type = "prometheus";
                uid = "mimir";
                access = "proxy";
                url = "http://mimir.snix.dev:9009/prometheus";
                isDefault = true;
              }
              {
                name = "Loki";
                type = "loki";
                uid = "loki";
                access = "proxy";
                url = "http://loki.snix.dev:9090/";
              }
              {
                name = "Tempo";
                type = "tempo";
                uid = "tempo";
                access = "proxy";
                url = "http://tempo.snix.dev:9190";
                jsonData.streamingEnabled.search = true;
              }
              {
                name = "Mimir Alertmanager";
                type = "alertmanager";
                uid = "mimir-alertmanager";
                access = "proxy";
                url = "http://mimir.snix.dev:9009/";
                jsonData = {
                  handleGrafanaManagedAlerts = true;
                  implementation = "mimir";
                };
              }

              # {
              #   name = "Pyroscope";
              #   type = "grafana-pyroscope-datasource";
              #   uid = "pyroscope";
              #   access = "proxy";
              #   url = "http://127.0.0.1:4040";
              # }
            ];
          };
        };
      };

      postgresql = {
        ensureDatabases = [ "grafana" ];
        ensureUsers = [
          {
            name = "grafana";
            ensureDBOwnership = true;
          }
        ];
      };
    };

    infra.monitoring.alloy.exporters.grafana.port = 2342;
  };
}
