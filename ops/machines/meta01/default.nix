{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system

let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    ./disko.nix

    (mod "hetzner-cloud.nix")
    (mod "o11y/alloy.nix")
    (mod "o11y/mimir.nix")
    (mod "o11y/loki.nix")
    (mod "o11y/tempo.nix")
    (mod "o11y/alertmanager-irc-relay.nix")
    (mod "known-hosts.nix")
    (mod "irccat.nix")

    (mod "www/mimir.snix.dev.nix")
    (mod "www/loki.snix.dev.nix")
    (mod "www/tempo.snix.dev.nix")

    (depot.third_party.agenix.src + "/modules/age.nix")
    (depot.third_party.disko.src + "/module.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  infra.hardware.hetzner-cloud = {
    enable = true;
    ipv6 = "2a01:4f8:c013:4a58::1/64";
  };

  networking = {
    hostName = "meta01";
    domain = "infra.snix.dev";
  };

  time.timeZone = "UTC";

  programs.mtr.enable = true;
  programs.mosh.enable = true;
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  nix.gc.automatic = true;

  services.depot = {
    # TODO: make it possible to do `alertmanager.enable = true;`
    prometheus.enable = true;
    loki.enable = true;
    tempo.enable = true;
  };

  services.irccat = {
    enable = true;
    config = {
      # FUTUREWORK: disable tcp listener entirely
      # Maybe this is https://github.com/spf13/viper/issues/323#issuecomment-309570752 ?
      tcp.listen = "127.0.0.1:4723";
      http.listen = "127.0.0.1:4722";
      http.listeners.generic = { };
      irc = {
        server = "irc.eu.hackint.org:6697";
        tls = true;
        sasl_pass = "filled_in_by_secret";
        nick = "snixbot";
        channels = [
          "#snix"
        ];
      };
    };
    secretsFile = config.age.secrets.irccat-secrets.path;
  };

  networking.nftables.enable = true;
  networking.firewall.extraInputRules = ''
    # Prometheus, Loki, Tempo
    ip6 saddr { 2a01:4f8:c013:3e62::1 } tcp dport { 9009, 9090, 9190 } accept
    ip saddr { 49.13.70.233 } tcp dport { 9009, 9090, 9190 } accept
  '';

  age.secrets =
    let
      secretFile = name: depot.ops.secrets."${name}.age";
    in
    {
      mimir-environment.file = secretFile "mimir-environment";
      # Yes, they are literally the same: Hetzner Cloud has no support for per-bucket keys.
      loki-environment.file = secretFile "mimir-environment";
      tempo-environment.file = secretFile "mimir-environment";
      metrics-push-htpasswd.file = secretFile "metrics-push-htpasswd";
      metrics-push-htpasswd.owner = "nginx";
      mimir-webhook-url.file = secretFile "mimir-webhook-url";
      alertmanager-irc-relay-environment.file = secretFile "alertmanager-irc-relay-environment";
      irccat-secrets.file = secretFile "irccat-secrets";
      restic-repository-password.file = secretFile "restic-repository-password";
      restic-bucket-credentials.file = secretFile "restic-bucket-credentials";
    };

  services.fail2ban.enable = true;

  environment.systemPackages = with pkgs; [
    bat
    bb
    curl
    direnv
    fd
    git
    htop
    hyperfine
    jq
    nano
    nvd
    ripgrep
    tree
    unzip
    vim
  ];

  # Required for prometheus to be able to scrape stats
  services.nginx.statusPage = true;

  users.users.root.openssh.authorizedKeys.keys = depot.ops.users.edef ++ depot.ops.users.flokli ++ depot.ops.users.raito;

  boot.initrd.systemd.enable = true;
  zramSwap.enable = true;

  system.stateVersion = "25.05";
}
