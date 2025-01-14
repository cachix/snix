{ config, ... }:

{
  imports = [
    ./base.nix
  ];

  config = {
    services.nginx.virtualHosts."nixery.dev" = {
      serverName = "nixery.dev";
      enableACME = true;
      forceSSL = true;

      acmeFallbackHost = {
        "nixery-01" = "bugry.tvl.fyi";
        "bugry" = "nixery-01.tvl.fyi";
      }."${config.networking.hostName}";

      extraConfig = ''
        location / {
          proxy_pass http://localhost:${toString config.services.depot.nixery.port};
        }
      '';
    };
  };
}
