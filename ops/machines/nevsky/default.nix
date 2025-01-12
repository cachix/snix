{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system

let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    (mod "tvl-users.nix")
    (depot.third_party.agenix.src + "/modules/age.nix")
  ];

  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  boot = {
    tmp.useTmpfs = true;
    kernelModules = [ "kvm-amd" ];
    supportedFilesystems = [ "zfs" ];
    kernelParams = [
      "ip=188.225.81.75::188.225.81.1:255.255.255.0:nevsky:enp1s0f0np0:none"
    ];

    initrd = {
      availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "ice" ];

      # initrd SSH for disk unlocking
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          authorizedKeys =
            depot.users.tazjin.keys.all
            ++ depot.users.lukegb.keys.all
            ++ depot.users.sterni.keys.all;

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

    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    zfs.requestEncryptionCredentials = true;
  };

  fileSystems = {
    "/" = {
      device = "tank/root";
      fsType = "zfs";
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/CCB4-8821";
      fsType = "vfat";
    };

    "/nix" = {
      device = "tank/nix";
      fsType = "zfs";
    };

    "/home" = {
      device = "tank/home";
      fsType = "zfs";
    };

    "/depot" = {
      device = "tank/depot";
      fsType = "zfs";
    };
  };

  age.secrets = {
    wg-privkey.file = depot.ops.secrets."wg-nevsky.age";
  };

  networking = {
    hostName = "nevsky";
    domain = "tvl.fyi";
    hostId = "0117d088";
    useDHCP = false;

    interfaces.enp1s0f0np0.ipv4.addresses = [{
      address = "188.225.81.75";
      prefixLength = 24;
    }];

    defaultGateway = "188.225.81.1";

    interfaces.enp1s0f0np0.ipv6.addresses = [{
      address = "2a03:6f00:2:514b:0:feed:edef:beef";
      prefixLength = 64;
    }];

    defaultGateway6 = {
      address = "2a03:6f00:2:514b::1";
      interface = "enp1s0f0np0";
    };

    wireguard.interfaces.wg-bugry = {
      ips = [ "2a03:6f00:2:514b:5bc7:95ef::1/96" ];
      privateKeyFile = "/run/agenix/wg-privkey";
      listenPort = 51820;

      postSetup = ''
        ${pkgs.iptables}/bin/ip6tables -t nat -A POSTROUTING -s '2a03:6f00:2:514b:5bc7:95ef::1/96' -o enp1s0f0np0 -j MASQUERADE
      '';

      postShutdown = ''
        ${pkgs.iptables}/bin/ip6tables -t nat -D POSTROUTING -s '2a03:6f00:2:514b:5bc7:95ef::1/96' -o enp1s0f0np0 -j MASQUERADE
      '';

      peers = [{
        publicKey = "+vFeWLH99aaypitw7x1J8IypoTrva28LItb1v2VjOAg="; # bugry
        allowedIPs = [ "2a03:6f00:2:514b:5bc7:95ef::/96" ];
      }];

      allowedIPsAsRoutes = true;
    };

    nameservers = [
      "8.8.8.8"
      "8.8.4.4"
    ];

    firewall.allowedTCPPorts = [ 22 80 443 ];
    firewall.allowedUDPPorts = [ 51820 ];
  };

  # Generate an immutable /etc/resolv.conf from the nameserver settings
  # above (otherwise DHCP overwrites it):
  environment.etc."resolv.conf" = with lib; {
    source = pkgs.writeText "resolv.conf" ''
      ${concatStringsSep "\n" (map (ns: "nameserver ${ns}") config.networking.nameservers)}
      options edns0
    '';
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  services.fail2ban.enable = true;

  programs.mtr.enable = true;
  programs.mosh.enable = true;

  time.timeZone = "UTC";
  nixpkgs.hostPlatform = "x86_64-linux";

  services.fwupd.enable = true;

  # Join TVL Tailscale network at net.tvl.fyi
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
    }
  ];

  zramSwap.enable = true;

  system.stateVersion = "24.11";
}
