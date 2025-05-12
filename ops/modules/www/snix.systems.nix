{ depot, ... }:

{
  imports = [
    ./base.nix
  ];

  config = {
    services.nginx.virtualHosts."snix.systems" = {
      enableACME = true;
      forceSSL = true;
      root = depot.fun.solves-this.snix;
    };
    services.nginx.virtualHosts."tvix.systems" = {
      enableACME = true;
      forceSSL = true;
      root = depot.fun.solves-this.tvix;
    };
  };
}
