{ config, ... }:
{
  imports = [
    ./base.nix
  ];

  services.nginx = {
    upstreams.tempo = {
      servers."${config.services.tempo.settings.distributor.receivers.otlp.protocols.http.endpoint}" = { };
    };

    virtualHosts."tempo.snix.dev" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://tempo";
        basicAuthFile = config.age.secrets.metrics-push-htpasswd.path;
      };
    };
  };
}
