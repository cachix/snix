# Disk /dev/nvme0n1: 1024 GB (=> 953 GiB)
# Disk /dev/nvme1n1: 1024 GB (=> 953 GiB)
# Disk /dev/sda: 22 TB (=> 20 TiB)
# Disk /dev/sdb: 22 TB (=> 20 TiB)
# Disk /dev/sdc: 22 TB (=> 20 TiB)
# Disk /dev/sdd: 22 TB (=> 20 TiB)
#
# # Installation
# 1. Comment out the fileSystems
# 2. Bootstrap the machine with `clan machines tvix-cache-install`
# 3. Do the btrfs partitioning by hand (because it's not supported by Disko)
#   a. `mkfs.btrfs -m raid1 -d single /dev/sd{a,b,c,d} --label tank -f`
#   b. `mkdir /tank && mount /dev/disk/by-label/tank /tank`
# 4. Uncomment the fileSystems section below
# 5. Re-deploy
#
# TODO: make use of /dev/nvme1n1
{
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 3;
  boot.supportedFilesystems = [ "btrfs" ];

  # TODO: comment me during install
  fileSystems."/tank" = {
    fsType = "btrfs";
    device = "/dev/disk/by-label/tank";
  };

  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "btrfs";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
