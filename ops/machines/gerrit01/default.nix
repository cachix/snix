{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system

let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    ./disko.nix

    (mod "hetzner-cloud.nix")
    (mod "restic.nix")
    (mod "o11y/alloy.nix")
    (mod "gerrit-autosubmit.nix")
    (mod "monorepo-gerrit.nix")
    (mod "www/cl.snix.dev.nix")
    (mod "known-hosts.nix")

    (depot.third_party.agenix.src + "/modules/age.nix")
    (depot.third_party.disko.src + "/module.nix")
  ];

  infra.hardware.hetzner-cloud = {
    enable = true;
    ipv6 = "2a01:4f8:c17:6188::1/64";
  };

  networking = {
    hostName = "gerrit01";
    domain = "infra.snix.dev";
  };

  # Disable background git gc system-wide, as it has a tendency to break CI.
  environment.etc."gitconfig".source = pkgs.writeText "gitconfig" ''
    [gc]
    autoDetach = false
  '';

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

  age.secrets =
    let
      secretFile = name: depot.ops.secrets."${name}.age";
    in
    {
      buildkite-api-proxy-token.file = secretFile "buildkite-api-proxy-token";
      gerrit-oauth-secret.file = secretFile "gerrit-oauth-secret";
      gerrit-replication-key.file = secretFile "gerrit-replication-key";
      gerrit-sendemail-smtp-pass.file = secretFile "gerrit-sendemail-smtp-pass";
      gerrit-autosubmit.file = secretFile "gerrit-autosubmit";
      gerrit-besadii-config = {
        file = secretFile "buildkite-besadii-config";
        owner = "git";
      };
      restic-repository-password.file = secretFile "restic-repository-password";
      restic-bucket-credentials.file = secretFile "restic-bucket-credentials";
    };

  services.depot = {
    gerrit-autosubmit.enable = true;
    restic.enable = true;
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

  users = {
    # Set up a user & group for git shenanigans
    groups.git = { };
    users.git = {
      group = "git";
      isSystemUser = true;
      createHome = true;
      home = "/var/lib/git";
    };
    users.root.openssh.authorizedKeys.keys = depot.ops.users.edef ++ depot.ops.users.flokli ++ depot.ops.users.raito;
  };

  boot.initrd.systemd.enable = true;
  zramSwap.enable = true;

  system.stateVersion = "25.05";
}
