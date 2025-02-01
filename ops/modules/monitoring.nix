# Runs the TVL Monitoring setup (currently Grafana + Prometheus).
{ depot, pkgs, config, lib, ... }:

{
  # Required for prometheus to be able to scrape stats
  services.nginx.statusPage = true;

  # Configure Prometheus & Grafana. Exporter configuration for
  # Prometheus is inside the respective service modules.
  services.prometheus = {
    enable = true;
    retentionTime = "90d";

    exporters = {
      node = {
        enable = true;

        enabledCollectors = [
          "logind"
          "processes"
          "systemd"
        ];
      };

      nginx = {
        enable = true;
        sslVerify = false;
        constLabels = [ "host=whitby" ];
      };
    };

    scrapeConfigs = [{
      job_name = "node";
      scrape_interval = "5s";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
      }];
    }
      {
        job_name = "nginx";
        scrape_interval = "5s";
        static_configs = [{
          targets = [ "localhost:${toString config.services.prometheus.exporters.nginx.port}" ];
        }];
      }];
  };

  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_port = 4723; # "graf" on phone keyboard
        domain = "status.tvl.su";
        root_url = "https://status.tvl.su";
      };

      analytics.reporting_enabled = false;

      "auth.generic_oauth" = {
        enabled = true;
        client_id = "grafana";
        scopes = "openid profile email";
        name = "TVL";
        email_attribute_path = "mail";
        login_attribute_path = "sub";
        name_attribute_path = "displayName";
        auth_url = "https://auth.tvl.fyi/auth/realms/TVL/protocol/openid-connect/auth";
        token_url = "https://auth.tvl.fyi/auth/realms/TVL/protocol/openid-connect/token";
        api_url = "https://auth.tvl.fyi/auth/realms/TVL/protocol/openid-connect/userinfo";

        # Give lukegb, aspen, tazjin "Admin" rights.
        role_attribute_path = "((sub == 'lukegb' || sub == 'aspen' || sub == 'tazjin') && 'Admin') || 'Editor'";

        # Allow creating new Grafana accounts from OAuth accounts.
        allow_sign_up = true;
      };

      "auth.anonymous" = {
        enabled = true;
        org_name = "The Virus Lounge";
        org_role = "Viewer";
      };

      "auth.basic".enabled = false;

      auth = {
        oauth_auto_login = true;
        disable_login_form = true;
      };
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [{
        name = "Prometheus";
        type = "prometheus";
        url = "http://localhost:9090";
      }];
    };
  };

  # Contains GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET.
  systemd.services.grafana.serviceConfig.EnvironmentFile = config.age.secretsDir + "/grafana";
}

