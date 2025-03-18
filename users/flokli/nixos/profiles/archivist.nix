# Set of unconditional config options applicable to all archivist machines.

{ pkgs, ... }:

{
  # Start clickhose as a system service.
  services.clickhouse.enable = true;

  # for ClickHouse
  # We're keeping this here rather than in the NixOS module, because I suspect
  # this opens up timing side channels. This is a single-user, single-purpose
  # machine, so that isn't a concern here.
  boot.kernel.sysctl."kernel.task_delayacct" = 1;

  # Enable SSH and let edef and flokli in
  services.openssh.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    "cert-authority ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCvb/7ojfcbKvHIyjnrNUOOgzy44tCkgXY9HLuyFta1jQOE9pFIK19B4dR9bOglPKf145CCL0mSFJNNqmNwwavU2uRn+TQrW+U1dQAk8Gt+gh3O49YE854hwwyMU+xD6bIuUdfxPr+r5al/Ov5Km28ZMlHOs3FoAP0hInK+eAibioxL5rVJOtgicrOVCkGoXEgnuG+LRbOYTwzdClhRUxiPjK8alCbcJQ53AeZHO4G6w9wTr+W5ILCfvW4OmUXCX01sKzaBiQuuFCF6M/H4LlnsPWLMra2twXxkOIhZblwC+lncps9lQaUgiD4koZeOCORvHW00G0L39ilFbbnVcL6Itp/m8RRWm/xRxS4RMnsdV/AhvpRLrhL3lfQ7E2oCeSM36v1S9rdg6a47zcnpL+ahG76Gz39Y7KmVRQciNx7ezbwxj3Q5lZtFykgdfGIAN+bT8ijXMO6m68g60i9Bz4IoMZGkiJGqMYLTxMQ+oRgR3Ro5lbj7E11YBHyeimoBYXYGHMkiuxopQZ7lIj3plxIzhmUlXJBA4jMw9KGHdYaLhaicIYhvQmCTAjrkt2HvxEe6lU8iws2Qv+pB6tAGundN36RVVWAckeQPZ4ZsgDP8V2FfibZ1nsrQ+zBKqaslYMAHs01Cf0Hm0PnCqagf230xaobu0iooNuXx44QKoDnB+w== edef"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTVTXOutUZZjXLB0lUSgeKcSY/8mxKkC0ingGK1whD2 flokli"
  ];

  # Get a bunch of text editors and CLI tools.
  environment.systemPackages = [
    pkgs.awscli
    pkgs.duckdb
    pkgs.parquet-tools
    pkgs.helix
    pkgs.htop
    pkgs.kakoune
    pkgs.kitty.terminfo
    pkgs.tmux
  ];
}
