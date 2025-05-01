{ depot, ... }:

{
  imports = [
    ./base.nix
  ];

  config = {
    services.nginx.virtualHosts.forgejo = {
      serverName = "git.snix.dev";
      enableACME = true;
      forceSSL = true;
      locations."=/robots.txt".alias = "${depot.third_party.sources.ai-robots-txt}/robots.txt";
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        extraConfig = ''
          include ${depot.third_party.sources.ai-robots-txt + "/nginx-block-ai-bots.conf"};

          proxy_ssl_server_name on;
          proxy_pass_header Authorization;

          # This has to be sufficiently large for uploading layers of
          # non-broken docker images.
          client_max_body_size 1G;
        '';
      };
    };
  };
}
