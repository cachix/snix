{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system

let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    ./disko.nix

    (mod "hetzner-cloud.nix")
    (mod "forgejo.nix")
    (mod "restic.nix")
    # Automatically enable metric and log collection.
    (mod "o11y/alloy.nix")
    (mod "o11y/grafana.nix")
    (mod "www/snix.dev.nix")
    (mod "www/bolt.snix.dev.nix")
    (mod "www/status.snix.dev.nix")
    (mod "www/auth.snix.dev.nix")
    (mod "www/git.snix.dev.nix")
    (mod "www/cache.snix.dev.nix")
    (mod "www/snix.systems.nix")
    (mod "known-hosts.nix")

    (depot.third_party.agenix.src + "/modules/age.nix")
    (depot.third_party.disko.src + "/module.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  infra.hardware.hetzner-cloud = {
    enable = true;
    ipv6 = "2a01:4f8:c013:3e62::1/64";
  };

  networking = {
    hostName = "public01";
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
    forgejo = {
      enable = true;
      domain = "git.snix.dev";
    };
    grafana.enable = true;
    # Configure backups to Hetzner Cloud
    restic = {
      enable = true;
      paths = [
        "/var/backup/postgresql"
        "/var/backup/mysql"
        "/var/lib/grafana"
        "/var/lib/forgejo"
      ];
    };
  };

  services.postgresqlBackup = {
    enable = true;
    databases = [
      "keycloak"
    ];
  };

  services.mysqlBackup = {
    enable = true;
    databases = [
      "forgejo"
    ];
  };

  services.keycloak = {
    enable = true;

    settings = {
      http-port = 9091;
      hostname = "auth.snix.dev";
      proxy-headers = "xforwarded";
      http-enabled = true;

      # https://www.keycloak.org/docs/latest/server_admin/#_fine_grain_permissions
      features = "admin-fine-grained-authz";
    };

    # This will be immediately changed, so no harm in having it here.
    # It's just a one-time-use random set of characters.
    initialAdminPassword = "TUxLWjndUZQGQ0A3ws0LfUs1DYRdAVcK";

    database = {
      type = "postgresql";
      createLocally = true;
      passwordFile = config.age.secrets.keycloak-db-password.path;
    };
  };

  systemd.services.keycloak.serviceConfig.Environment = [
    # https://bugs.openjdk.org/browse/JDK-8170568 someday… !
    "JAVA_OPTS_APPEND=-Djava.net.preferIPv6Addresses=system"
  ];

  age.secrets =
    let
      secretFile = name: depot.ops.secrets."${name}.age";
    in
    {
      forgejo-oauth-secret = {
        file = secretFile "forgejo-oauth-secret";
        mode = "0440";
        group = "git";
      };
      forgejo-smtp-passwd.file = secretFile "forgejo-smtp-passwd";
      grafana-oauth-secret = {
        file = secretFile "grafana-oauth-secret";
        mode = "0440";
        owner = "grafana";
      };
      keycloak-db-password.file = secretFile "keycloak-db-password";
      restic-repository-password.file = secretFile "restic-repository-password";
      restic-bucket-credentials.file = secretFile "restic-bucket-credentials";
    };

  # Start the Gerrit->IRC bot
  # services.depot.clbot = {
  #   enable = true;
  #   channels = {
  #     "#snix-dev" = { };
  #   };

  #   # See //fun/clbot for details.
  #   flags = {
  #     gerrit_host = "cl.tvl.fyi:29418";
  #     gerrit_ssh_auth_username = "clbot";
  #     gerrit_ssh_auth_key = config.age.secretsDir + "/clbot-ssh";

  #     irc_server = "localhost:${toString config.services.znc.config.Listener.l.Port}";
  #     irc_user = "tvlbot";
  #     irc_nick = "tvlbot";

  #     notify_branches = "canon,refs/meta/config";
  #     notify_repo = "depot";

  #     # This secret is read from an environment variable, which is
  #     # populated by a systemd EnvironmentFile.
  #     irc_pass = "$CLBOT_PASS";
  #   };
  # };

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
