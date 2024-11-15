{ config, pkgs, lib, depot, ... }:

let
  ipv6 = "2a01:4f9:2a:1bc6::/64";

  ipv4 = "95.216.27.158";
  gatewayv4 = "95.216.27.129";
  netmaskv4 = "255.255.255.192";
in

{
  config = {
    boot = {
      kernelParams = [
        "ip=${ipv4}::${gatewayv4}:${netmaskv4}::eth0:none"
      ];

      initrd.network = {
        enable = true;
        ssh = {
          # ssh_config:
          # Host ingeborg-unlock
          #     User root
          #     HostName ingeborg.sterni.lv
          #     AddressFamily inet # kernel commandline only gives ipv4
          #     Port 22
          #     UserKnownHostsFile /home/lukas/.ssh/initrd_known_hosts
          enable = true;
          authorizedKeys = depot.users.sterni.keys.all;
          hostKeys = [
            "/etc/nixos/unlock_rsa_key_openssh"
            "/etc/nixos/unlock_ed25519_key_openssh"
          ];
        };
        postCommands = ''
          echo 'cryptsetup-askpass' >> /root/.profile
        '';
      };
    };

    networking = {
      usePredictableInterfaceNames = false;
      useDHCP = false;
      interfaces."eth0".useDHCP = false;

      hostName = "ingeborg";

      firewall = {
        enable = true;
        allowPing = true;
        allowedTCPPorts = [ 22 ];
      };
    };

    systemd.network = {
      enable = true;
      networks."eth0".extraConfig = ''
        [Match]
        Name = eth0

        [Network]
        Address = ${ipv6}
        Gateway = fe80::1
        Address = ${ipv4}/27
        Gateway = ${gatewayv4}
      '';
    };
  };
}
