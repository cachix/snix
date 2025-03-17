{ config, ... }:

{
  imports = [
    ./base.nix
  ];

  config = {
    services.nginx.virtualHosts."cl-shortlink" = {
      serverName = "cl";
      extraConfig = "return 302 https://cl.snix.dev$request_uri;";
    };

    services.nginx.virtualHosts.gerrit = {
      serverName = "cl.snix.dev";
      enableACME = true;
      forceSSL = true;

      extraConfig = ''
        location / {
          proxy_pass http://localhost:4778;
          proxy_set_header  X-Forwarded-For $remote_addr;
          # The :443 suffix is a workaround for https://b.snix.dev/issues/88.
          proxy_set_header  Host $host:443;
        }

        # Retro-compatibility to TVL shortlinks.
        location ~ "^/q/([1-2]?[0-9]{1,4}|30000)$" {
          return 302 https://cl.tvl.fyi$request_uri;
        }

        location = /robots.txt {
          return 200 'User-agent: *\nAllow: /';
        }
      '';
    };
  };
}
