{ config, lib, pkgs, depot, ... }:

let
  cfg = config.services.prometheus-fail2ban-exporter;
in

{
  options.services.prometheus-fail2ban-exporter = with lib; {
    enable = mkEnableOption "Prometheus Fail2ban Exporter";

    interval = mkOption {
      description = "Systemd calendar expression for how often to run the interval";
      type = types.str;
      default = "minutely";
      example = "hourly";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services."prometheus-fail2ban-exporter" = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "fail2ban.service" ];
      serviceConfig = {
        User = "root";
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "prometheus-fail2ban-exporter" ''
          set -eo pipefail
          mkdir -p /var/lib/prometheus/node-exporter
          exec prometheus-fail2ban-exporter
        '';
      };

      path = [
        pkgs.fail2ban
        depot.third_party.prometheus-fail2ban-exporter
      ];
    };

    systemd.timers."prometheus-fail2ban-exporter" = {
      wantedBy = [ "multi-user.target" ];
      timerConfig.OnCalendar = cfg.interval;
    };

    services.prometheus.exporters.node = {
      enabledCollectors = [ "textfile" ];

      extraFlags = [
        "--collector.textfile.directory=/var/lib/prometheus/node-exporter"
      ];
    };
  };
}
