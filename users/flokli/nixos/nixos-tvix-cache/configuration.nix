{ pkgs
, lib
, config
, ...
}:

let
  srvos =
    import (builtins.fetchTarball {
      url = "https://github.com/nix-community/srvos/archive/15b152766b329dd2957549a49f0fd96a7a861db1.tar.gz";
      sha256 = "sha256-11TCdlxJEf84Lm2KIJGL8J2nJ2G9CNTW8PrCebJLg/M=";
    });
  disko =
    (builtins.fetchTarball {
      url = "https://github.com/nix-community/disko/archive/84dd8eea9a06006d42b8af7cfd4fda4cf334db81.tar.gz";
      sha256 = "13mfnjnjp21wms4mw35ar019775qgy3fnjc59zrpnqbkfmzyvv02";
    });


in
{
  imports = [
    "${disko}/module.nix"
    ./disko.nix
    ./monitoring.nix
    ./nar-bridge.nix
    srvos.nixosModules.hardware-hetzner-online-amd
    srvos.nixosModules.mixins-nginx
  ];

  options = {
    machine.domain = lib.mkOption {
      type = lib.types.str;
      default = "nixos.tvix.store";
    };
  };

  config = {
    services.nginx.virtualHosts."${config.machine.domain}" = {
      enableACME = true;
      forceSSL = true;
    };


    security.acme.acceptTerms = true;
    security.acme.defaults.email = "admin+acme@numtide.com";

    nixpkgs.hostPlatform = "x86_64-linux";

    networking.hostName = "tvix-cache";

    systemd.network.networks."10-uplink".networkConfig.Address = "2a01:4f9:3071:1091::2/64";


    # Enable SSH and add some keys
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [
      # edef
      "cert-authority ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCvb/7ojfcbKvHIyjnrNUOOgzy44tCkgXY9HLuyFta1jQOE9pFIK19B4dR9bOglPKf145CCL0mSFJNNqmNwwavU2uRn+TQrW+U1dQAk8Gt+gh3O49YE854hwwyMU+xD6bIuUdfxPr+r5al/Ov5Km28ZMlHOs3FoAP0hInK+eAibioxL5rVJOtgicrOVCkGoXEgnuG+LRbOYTwzdClhRUxiPjK8alCbcJQ53AeZHO4G6w9wTr+W5ILCfvW4OmUXCX01sKzaBiQuuFCF6M/H4LlnsPWLMra2twXxkOIhZblwC+lncps9lQaUgiD4koZeOCORvHW00G0L39ilFbbnVcL6Itp/m8RRWm/xRxS4RMnsdV/AhvpRLrhL3lfQ7E2oCeSM36v1S9rdg6a47zcnpL+ahG76Gz39Y7KmVRQciNx7ezbwxj3Q5lZtFykgdfGIAN+bT8ijXMO6m68g60i9Bz4IoMZGkiJGqMYLTxMQ+oRgR3Ro5lbj7E11YBHyeimoBYXYGHMkiuxopQZ7lIj3plxIzhmUlXJBA4jMw9KGHdYaLhaicIYhvQmCTAjrkt2HvxEe6lU8iws2Qv+pB6tAGundN36RVVWAckeQPZ4ZsgDP8V2FfibZ1nsrQ+zBKqaslYMAHs01Cf0Hm0PnCqagf230xaobu0iooNuXx44QKoDnB+w== edef"
      # flokli
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTVTXOutUZZjXLB0lUSgeKcSY/8mxKkC0ingGK1whD2 flokli"
      # mic92
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbBp2dH2X3dcU1zh+xW3ZsdYROKpJd3n13ssOP092qE"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCsjXKHCkpQT4LhWIdT0vDM/E/3tw/4KHTQcdJhyqPSH0FnwC8mfP2N9oHYFa2isw538kArd5ZMo5DD1ujL5dLk= ssh@secretive.Joerg’s-Laptop.local"
      # padraic
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEFlro/QUDlDpaA1AQxdWIqBg9HSFJf9Cb7CPdsh0JN7"
      # zimbatm
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuiDoBOxgyer8vGcfAIbE6TC4n4jo8lhG9l01iJ0bZz zimbatm@no1"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAINwWC6CJ/E6o3WGeZxbZMajC4roXnzVi8fOo1JYJSE6YAAAABHNzaDo= zimbatm@nixos"
    ];

    environment.systemPackages = [
      pkgs.helix
      pkgs.htop
      pkgs.kitty.terminfo
      pkgs.tmux
    ];

    system.stateVersion = "24.11";
  };
}
