{ config, lib, pkgs, depot, ... }:

{
  # Booting / Kernel
  boot = {
    loader.grub = {
      enable = true;
      devices = [
        "/dev/disk/by-id/wwn-0x5000c500a4859731"
        "/dev/disk/by-id/wwn-0x5000c500a485c1b5"
      ];
    };

    initrd = {
      availableKernelModules = [
        "ahci"
        "btrfs"
        "sd_mod"
        "xhci_pci"
        "e1000e"
        "usbhid"
      ];
      kernelModules = [
        "dm-snapshot"
      ];
    };

    swraid = {
      enable = true;
      mdadmConf = ''
        ARRAY /dev/md/boot-raid metadata=1.2 name=nixos:boot-raid UUID=13007b9d:ab7a1129:c45ec40f:3c9f2111
        ARRAY /dev/md/encrypted-container-raid metadata=1.2 name=nixos:encrypted-container-raid UUID=38dfa683:a6d30690:32a5de6f:fb7980fe
      '';
    };

    kernelModules = [
      "kvm-intel"
    ];
  };

  # Filesystems
  services.lvm.enable = true;

  boot.initrd.luks.devices."container" = {
    device = "/dev/md/encrypted-container-raid";
    preLVM = true;
  };

  fileSystems = {
    "/" = {
      device = "/dev/mainvg/root";
      fsType = "btrfs";
    };

    "/boot" = {
      device = "/dev/disk/by-label/boot";
      fsType = "ext4";
    };
  };

  swapDevices = [
    { device = "/dev/mainvg/swap"; }
  ];

  # CPU
  hardware = {
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    enableRedistributableFirmware = true;
  };

  nix.settings = {
    max-jobs = 2;
    cores = 4;
  };

  powerManagement.cpuFreqGovernor = "performance";
}
