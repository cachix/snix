{ depot, lib, pkgs, ... }:

config:
let
  inherit (pkgs) lieer;

  quasselClient = pkgs.quassel.override {
    client = true;
    enableDaemon = false;
    monolithic = false;
  };
in
lib.fix (self: {
  boot = {
    tmp.useTmpfs = true;
    kernelModules = [ "kvm-amd" ];

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd = {
      luks.devices.frog-crypt.device = "/dev/disk/by-label/frog-crypt";
      availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
      kernelModules = [ "dm-snapshot" ];
    };

    kernelPackages = pkgs.linuxPackages_latest;
    kernel.sysctl = {
      "kernel.perf_event_paranoid" = -1;
    };

    # Enable this again if frog is put back into use ...
    #
    # kernelPatches = [
    #   depot.third_party.kernelPatches.trx40_usb_audio
    # ];
  };

  hardware = {
    cpu.amd.updateMicrocode = true;
    enableRedistributableFirmware = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };

    bluetooth = {
      enable = true;
    };
  };

  services.pulseaudio = {
    enable = true;
    package = pkgs.pulseaudioFull;
  };

  nix.settings = {
    max-jobs = 48;
    substituters = [ "ssh://nix-ssh@whitby.tvl.fyi" ];
  };

  networking = {
    hostName = "frog";
    useDHCP = true;

    # Don't use ISP's DNS servers:
    nameservers = [
      "8.8.8.8"
      "8.8.4.4"
    ];

    firewall.enable = false;
  };

  # Generate an immutable /etc/resolv.conf from the nameserver settings
  # above (otherwise DHCP overwrites it):
  environment.etc."resolv.conf" = with lib; {
    source = pkgs.writeText "resolv.conf" ''
      ${concatStringsSep "\n" (map (ns: "nameserver ${ns}") self.networking.nameservers)}
      options edns0
    '';
  };

  time.timeZone = "Europe/London";

  fileSystems = {
    "/".device = "/dev/disk/by-label/frog-root";
    "/boot".device = "/dev/disk/by-label/BOOT";
    "/home".device = "/dev/disk/by-label/frog-home";
  };

  # Configure user account
  users.extraUsers.tazjin = {
    extraGroups = [ "wheel" "audio" "docker" ];
    isNormalUser = true;
    uid = 1000;
    shell = pkgs.fish;
  };

  security.sudo = {
    enable = true;
    extraConfig = "wheel ALL=(ALL:ALL) SETENV: ALL";
  };

  fonts = {
    packages = with pkgs; [
      corefonts
      dejavu_fonts
      jetbrains-mono
      noto-fonts-cjk-sans
      noto-fonts-emoji
    ];

    fontconfig = {
      hinting.enable = true;
      subpixel.lcdfilter = "light";

      defaultFonts = {
        monospace = [ "JetBrains Mono" ];
      };
    };
  };

  # Configure location (Vauxhall, London) for services that need it.
  location = {
    latitude = 51.4819109;
    longitude = -0.1252998;
  };

  programs.fish.enable = true;
  programs.ssh.startAgent = true;

  services.redshift.enable = true;
  services.openssh.enable = true;
  services.fstrim.enable = true;
  services.blueman.enable = true;

  # Required for Yubikey usage as smartcard
  services.pcscd.enable = true;
  services.udev.packages = [
    pkgs.yubikey-personalization
  ];

  # Enable Docker for Nixery testing
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  services.xserver = {
    enable = true;
    xkb.layout = "us";
    xkb.options = "caps:super";
    exportConfiguration = true;
    videoDrivers = [ "amdgpu" ];
    displayManager = {
      # Give EXWM permission to control the session.
      sessionCommands = "${pkgs.xorg.xhost}/bin/xhost +SI:localuser:$USER";

      lightdm.enable = true;
      lightdm.greeters.gtk.clock-format = "%H·%M"; # TODO(tazjin): TZ?
    };

    windowManager.session = lib.singleton {
      name = "exwm";
      start = "${depot.users.tazjin.emacs}/bin/tazjins-emacs";
    };
  };

  # Do not restart the display manager automatically
  systemd.services.display-manager.restartIfChanged = lib.mkForce false;

  # clangd needs more than ~2GB in the runtime directory to start up
  services.logind.extraConfig = ''
    RuntimeDirectorySize=16G
  '';

  # Configure email setup
  systemd.user.services.lieer-tazjin = {
    description = "Synchronise mail@tazj.in via lieer";
    script = "${lieer}/bin/gmi sync";

    serviceConfig = {
      WorkingDirectory = "%h/mail/account.tazjin";
      Type = "oneshot";
    };
  };

  systemd.user.timers.lieer-tazjin = {
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnActiveSec = "1";
      OnUnitActiveSec = "180";
    };
  };

  environment.systemPackages =
    # programs from the depot
    (with depot; [
      fun.idual.script
      fun.uggc
      lieer
      ops.kontemplate
      quasselClient
      third_party.git
      tools.nsfv-setup
      users.tazjin.emacs
    ]) ++

    # programs from nixpkgs
    (with pkgs; [
      age
      bat
      chromium
      clang-manpages
      clang-tools
      clang
      curl
      direnv
      dnsutils
      emacs # mostly for emacsclient
      fd
      file
      gdb
      gnupg
      go
      google-chrome
      google-cloud-sdk
      htop
      hyperfine
      i3lock
      iftop
      imagemagick
      jq
      kubectl
      linuxPackages.perf
      man-pages
      miller
      msmtp
      nix-prefetch-github
      notmuch
      obs-studio
      openssh
      openssl
      pass
      pavucontrol
      pciutils
      pinentry
      pinentry-emacs
      pmutils
      pwgen
      ripgrep
      rustup
      screen
      spotify
      tokei
      transmission
      tree
      unzip
      usbutils
      v4l-utils
      vlc
      xclip
      xsecurelock
      yubico-piv-tool
      yubikey-personalization
      zoxide

      # Commented out because of interim breakage:
      # steam
      # lutris
    ]);

  # ... and other nonsense.
  system.stateVersion = "20.03";
})
