# This file configures camden.tazj.in, my homeserver.
{ depot, pkgs, lib, ... }:

config:
let
  nginxRedirect = { from, to, acmeHost }: {
    serverName = from;
    useACMEHost = acmeHost;
    forceSSL = true;

    extraConfig = "return 301 https://${to}$request_uri;";
  };
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
lib.fix (self: {
  imports = [
    (mod "quassel.nix")
    (mod "smtprelay.nix")
  ];

  # camden is intended to boot unattended, despite having an encrypted
  # root partition.
  #
  # The below configuration uses an externally connected USB drive
  # that contains a LUKS key file to unlock the disk automatically at
  # boot.
  #
  # TODO(tazjin): Configure LUKS unlocking via SSH instead.
  boot = {
    initrd = {
      availableKernelModules = [
        "ahci"
        "xhci_pci"
        "usbhid"
        "usb_storage"
        "sd_mod"
        "sdhci_pci"
        "rtsx_usb_sdmmc"
        "r8169"
      ];

      kernelModules = [ "dm-snapshot" ];

      luks.devices.camden-crypt = {
        fallbackToPassword = true;
        device = "/dev/disk/by-label/camden-crypt";
        keyFile = "/dev/sdb";
        keyFileSize = 4096;
      };
    };

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    tmp.cleanOnBoot = true;
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/camden-root";
      fsType = "ext4";
    };

    "/home" = {
      device = "/dev/disk/by-label/camden-home";
      fsType = "ext4";
    };

    "/boot" = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
    };
  };

  nix.settings = {
    max-jobs = lib.mkDefault 4;
    trusted-users = [ "root" "tazjin" ];
    substituters = [
      "https://tazjin.cachix.org"
    ];

    trusted-public-keys = [
      "tazjin.cachix.org-1:IZkgLeqfOr1kAZjypItHMg1NoBjm4zX9Zzep8oRSh7U="
    ];
  };

  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  networking = {
    hostName = "camden";
    interfaces.enp1s0.useDHCP = true;
    interfaces.enp1s0.ipv6.addresses = [
      {
        address = "2a01:4b00:821a:ce02::5";
        prefixLength = 64;
      }
    ];

    firewall.enable = false;
  };

  time.timeZone = "UTC";

  # System-wide application setup
  programs.fish.enable = true;
  programs.mosh.enable = true;

  fonts = {
    packages = [ pkgs.jetbrains-mono ];
    fontconfig.defaultFonts.monospace = [ "JetBrains Mono" ];
  };

  environment.systemPackages =
    # programs from the depot
    (with depot; [
      fun.idual.script
      fun.idual.setAlarm
    ]) ++

    # programs from nixpkgs
    (with pkgs; [
      bat
      curl
      direnv
      emacs-nox
      fswebcam
      git
      gnupg
      google-cloud-sdk
      htop
      jq
      pass
      pciutils
      restic
      ripgrep
      screen
    ]);

  users = {
    # Set up my own user for logging in and doing things ...
    users.tazjin = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "git" "wheel" "quassel" "video" ];
      shell = pkgs.fish;
    };

    # Set up a user & group for general git shenanigans
    groups.git = { };
    users.git = {
      group = "git";
      isSystemUser = true;
    };
  };

  # Services setup
  services.openssh.enable = true;
  services.haveged.enable = true;

  # Join Tailscale into home network
  services.tailscale.enable = true;

  # Allow sudo-ing via the forwarded SSH agent.
  security.pam.sshAgentAuth.enable = true;

  # NixOS 20.03 broke nginx and I can't be bothered to debug it
  # anymore, all solution attempts have failed, so here's a
  # brute-force fix.
  systemd.services.fix-nginx = {
    script = "${pkgs.coreutils}/bin/chown -R nginx: /var/spool/nginx /var/cache/nginx";

    serviceConfig = {
      User = "root";
      Type = "oneshot";
    };
  };

  systemd.timers.fix-nginx = {
    wantedBy = [ "multi-user.target" ];
    timerConfig = {
      OnCalendar = "minutely";
    };
  };

  # Provision a TLS certificate outside of nginx to avoid
  # nixpkgs#38144
  security.acme = {
    acceptTerms = true;

    certs."tazj.in" = {
      email = "mail@tazj.in";
      group = "nginx";
      webroot = "/var/lib/acme/acme-challenge";
      postRun = "systemctl reload nginx";

      extraDomainNames = [
        "cs.tazj.in"
        "git.tazj.in"
        "www.tazj.in"

        # Local domains (for this machine only)
        "camden.tazj.in"
      ];
    };

    certs."quassel.tazj.in" = {
      email = "mail@tazj.in";
      webroot = "/var/lib/acme/challenge-quassel";
      group = "quassel";
    };
  };

  # Forward logs to Google Cloud Platform
  services.journaldriver = {
    enable = true;
    logStream = "home";
    googleCloudProject = "tazjins-infrastructure";
    applicationCredentials = "/etc/gcp/key.json";
  };

  services.depot.quassel = {
    enable = true;
    acmeHost = "quassel.tazj.in";
    bindAddresses = [
      "0.0.0.0"
    ];
  };

  services.bitlbee = {
    enable = false;
    portNumber = 2337; # bees
  };

  # serve my website(s)
  services.nginx = {
    enable = true;
    enableReload = true;
    package = with pkgs; nginx.override {
      modules = [ nginxModules.rtmp ];
    };

    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    appendConfig = ''
      rtmp_auto_push on;
      rtmp {
        server {
          listen 1935;
          chunk_size 4000;

          application tvl {
            live on;

            allow publish 88.98.195.213;
            allow publish 10.0.1.0/24;
            deny publish all;

            allow play all;
          }
        }
      }
    '';

    commonHttpConfig = ''
      log_format json_combined escape=json
      '{'
          '"remote_addr":"$remote_addr",'
          '"method":"$request_method",'
          '"uri":"$request_uri",'
          '"status":$status,'
          '"request_size":$request_length,'
          '"response_size":$body_bytes_sent,'
          '"response_time":$request_time,'
          '"referrer":"$http_referer",'
          '"user_agent":"$http_user_agent"'
      '}';

      access_log syslog:server=unix:/dev/log,nohostname json_combined;
    '';

    virtualHosts.homepage = {
      serverName = "tazj.in";
      serverAliases = [ "camden.tazj.in" ];
      default = true;
      useACMEHost = "tazj.in";
      root = depot.users.tazjin.homepage;
      forceSSL = true;

      extraConfig = ''
        ${depot.users.tazjin.blog.oldRedirects}

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

        location ~* \.(webp|woff2)$ {
          add_header Cache-Control "public, max-age=31536000";
        }

        location /blog/ {
          alias ${depot.users.tazjin.blog.rendered}/;

          if ($request_uri ~ ^/(.*)\.html$) {
            return 302 /$1;
          }

          try_files $uri $uri.html $uri/ =404;
        }

        location = /tazjin {
          return 200 "tazjin";
        }

        location /blobs/ {
          alias /var/www/blobs/;
        }
      '';
    };

    virtualHosts.cgit-old = nginxRedirect {
      from = "git.tazj.in";
      to = "code.tvl.fyi";
      acmeHost = "tazj.in";
    };

    virtualHosts.cs-old = nginxRedirect {
      from = "cs.tazj.in";
      to = "cs.tvl.fyi";
      acmeHost = "tazj.in";
    };
  };

  # Timer units that can be started with systemd-run to set my alarm.
  systemd.user.services.light-alarm = {
    script = "${depot.fun.idual.script}/bin/idualctl wakey";
    postStart = "${pkgs.systemd}/bin/systemctl --user stop light-alarm.timer";
    serviceConfig = {
      Type = "oneshot";
    };
  };

  system.stateVersion = "19.09";
})
