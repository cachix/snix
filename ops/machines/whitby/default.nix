{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system

let
  inherit (builtins) listToAttrs;
  inherit (lib) range;

  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    (mod "builderball.nix")
    (mod "harmonia.nix")
    (mod "journaldriver.nix")
    (mod "tvl-buildkite.nix")
    (mod "tvl-users.nix")
    (mod "www/cache.tvl.fyi.nix")
    (mod "www/cache.tvl.su.nix")
    (mod "www/self-cache.tvl.fyi.nix")
    (mod "www/self-redirect.nix")
    (mod "www/wigglydonke.rs.nix")

    (depot.third_party.agenix.src + "/modules/age.nix")
  ];

  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  boot = {
    tmp.useTmpfs = true;
    kernelModules = [ "kvm-amd" ];
    supportedFilesystems = [ "zfs" ];

    initrd = {
      availableKernelModules = [
        "igb"
        "xhci_pci"
        "nvme"
        "ahci"
        "usbhid"
        "usb_storage"
        "sr_mod"
      ];

      # Enable SSH in the initrd so that we can enter disk encryption
      # passwords remotely.
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          authorizedKeys =
            depot.users.tazjin.keys.all
            ++ depot.users.lukegb.keys.all
            ++ [ depot.users.aspen.keys.whitby ];

          hostKeys = [
            /etc/secrets/initrd_host_ed25519_key
          ];
        };

        # this will launch the zfs password prompt on login and kill the
        # other prompt
        postCommands = ''
          echo "zfs load-key -a && killall zfs" >> /root/.profile
        '';
      };
    };

    kernel.sysctl = {
      "net.ipv4.tcp_congestion_control" = "bbr";
    };

    loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      device = "/dev/disk/by-id/nvme-SAMSUNG_MZQLB1T9HAJR-00007_S439NA0N201620";
    };

    zfs.requestEncryptionCredentials = true;
  };

  fileSystems = {
    "/" = {
      device = "zroot/root";
      fsType = "zfs";
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/073E-7FBD";
      fsType = "vfat";
    };

    "/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
    };

    "/home" = {
      device = "zroot/home";
      fsType = "zfs";
    };
  };

  networking = {
    # Glass is boring, but Luke doesn't like Wapping - the Prospect of
    # Whitby, however, is quite a pleasant establishment.
    hostName = "whitby";
    domain = "tvl.fyi";
    hostId = "b38ca543";
    useDHCP = false;

    # Don't use Hetzner's DNS servers.
    nameservers = [
      "8.8.8.8"
      "8.8.4.4"
    ];

    defaultGateway6 = {
      address = "fe80::1";
      interface = "enp196s0";
    };

    firewall.allowedTCPPorts = [ 22 80 443 4238 8443 29418 ];
    firewall.allowedUDPPorts = [ 8443 ];

    interfaces.enp196s0.useDHCP = true;
    interfaces.enp196s0.ipv6.addresses = [
      {
        address = "2a01:04f8:0242:5b21::feed:edef:beef";
        prefixLength = 64;
      }
    ];
  };

  # Generate an immutable /etc/resolv.conf from the nameserver settings
  # above (otherwise DHCP overwrites it):
  environment.etc."resolv.conf" = with lib; {
    source = pkgs.writeText "resolv.conf" ''
      ${concatStringsSep "\n" (map (ns: "nameserver ${ns}") config.networking.nameservers)}
      options edns0
    '';
  };

  # Disable background git gc system-wide, as it has a tendency to break CI.
  environment.etc."gitconfig".source = pkgs.writeText "gitconfig" ''
    [gc]
    autoDetach = false
  '';

  time.timeZone = "UTC";

  nix = {
    nrBuildUsers = 256;
    settings = {
      max-jobs = lib.mkDefault 64;
      secret-key-files = "/run/agenix/nix-cache-priv";

      trusted-users = [
        "aspen"
        "lukegb"
        "tazjin"
        "sterni"
      ];
    };

    sshServe = {
      enable = true;
      keys = with depot.users;
        tazjin.keys.all
        ++ lukegb.keys.all
        ++ [ aspen.keys.whitby ]
        ++ sterni.keys.all
      ;
    };
  };

  programs.mtr.enable = true;
  programs.mosh.enable = true;
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Configure secrets for services that need them.
  age.secrets =
    let
      secretFile = name: depot.ops.secrets."${name}.age";
    in
    {
      clbot.file = secretFile "clbot";
      gerrit-autosubmit.file = secretFile "gerrit-autosubmit";
      grafana.file = secretFile "grafana";
      irccat.file = secretFile "irccat";
      keycloak-db.file = secretFile "keycloak-db";
      owothia.file = secretFile "owothia";
      panettone.file = secretFile "panettone";
      smtprelay.file = secretFile "smtprelay";
      teleirc.file = secretFile "teleirc";

      nix-cache-priv = {
        file = secretFile "nix-cache-priv";
        mode = "0440";
        group = "harmonia";
      };

      buildkite-agent-token = {
        file = secretFile "buildkite-agent-token";
        mode = "0440";
        group = "buildkite-agents";
      };

      buildkite-graphql-token = {
        file = secretFile "buildkite-graphql-token";
        mode = "0440";
        group = "buildkite-agents";
      };

      buildkite-besadii-config = {
        file = secretFile "besadii";
        mode = "0440";
        group = "buildkite-agents";
      };

      buildkite-private-key = {
        file = secretFile "buildkite-ssh-private-key";
        mode = "0440";
        group = "buildkite-agents";
      };

      gerrit-besadii-config = {
        file = secretFile "besadii";
        owner = "git";
      };

      gerrit-secrets = {
        file = secretFile "gerrit-secrets";
        path = "/var/lib/gerrit/etc/secure.config";
        owner = "git";
        mode = "0400";
      };

      clbot-ssh = {
        file = secretFile "clbot-ssh";
        owner = "clbot";
      };

      # Not actually a secret
      nix-cache-pub = {
        file = secretFile "nix-cache-pub";
        mode = "0444";
      };

      depot-replica-key = {
        file = secretFile "depot-replica-key";
        mode = "0500";
        owner = "git";
        group = "git";
        path = "/var/lib/git/.ssh/id_ed25519";
      };
    };

  # Automatically collect garbage from the Nix store.
  services.depot.automatic-gc = {
    enable = true;
    interval = "1 hour";
    diskThreshold = 200; # GiB
    maxFreed = 420; # GiB
    preserveGenerations = "90d";
  };

  # Run a handful of Buildkite agents to support parallel builds.
  services.depot.buildkite = {
    enable = true;
    agentCount = 32;
  };

  # Run Nix cache proxy
  services.depot.builderball.enable = true;

  # Run a Harmonia binary cache.
  #
  # TODO(tazjin): switch to upstream module after fix for Nix 2.3
  services.depot.harmonia = {
    enable = true;
    signKeyPaths = [ (config.age.secretsDir + "/nix-cache-priv") ];
    settings.bind = "127.0.0.1:6443";
    settings.priority = 50;
  };

  services.fail2ban.enable = true;

  # Join TVL Tailscale network at net.tvl.fyi
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server"; # for exit-node usage
  };

  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
    }
  ];

  zramSwap.enable = true;

  # Use TVL cache locally through the proxy; for cross-builder substitution.
  tvl.cache.enable = true;
  tvl.cache.builderball = true;

  system.stateVersion = "20.03";
}
