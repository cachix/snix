# Default configuration settings for physical machines that I use.
{ lib, pkgs, config, depot, ... }:

let
  pass-otp = pkgs.pass.withExtensions (e: [ e.pass-otp ]);
in
{
  options = with lib; {
    tazjin.emacs = mkOption {
      type = types.package;
      default = depot.users.tazjin.emacs;
      description = ''
        Derivation with my Emacs package, with configuration included.
      '';
    };
  };

  config = {
    # Install all the default software.
    environment.systemPackages =
      # programs from the depot
      (with depot; [
        config.tazjin.emacs
        third_party.agenix.cli
        tools.when
        users.tazjin.chase-geese
        users.tazjin.eaglemode
        users.tazjin.screenLock
      ]) ++

      # programs from nixpkgs
      (with pkgs; [
        (aspellWithDicts (d: [ d.ru ]))
        amber
        bat
        curl
        ddcutil
        direnv
        dnsutils
        electrum
        firefox
        config.tazjin.emacs.emacs # emacsclient
        expect
        fd
        file
        gdb
        git
        gnupg
        go
        gopls
        gotools
        gtk3 # for gtk-launch
        htop
        hyperfine
        iftop
        imagemagick
        josh
        jq
        lieer
        maim
        man-pages
        moreutils
        mosh
        msmtp
        networkmanagerapplet
        nix-prefetch-github
        nmap
        notmuch
        openssh
        openssl
        pass-otp
        pavucontrol
        pinentry
        pinentry-emacs
        pulseaudio # for pactl
        pwgen
        quasselClient
        radicle-node
        rink
        ripgrep
        rustup
        screen
        tig
        tokei
        tree
        unzip
        vlc
        volumeicon
        watchexec
        whois
        xclip
        xsecurelock
        zoxide
      ]);

    # Run services & configure programs for all machines.
    services.fwupd.enable = true;

    # Disable the broken NetworkManager-wait-online.service
    systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;

    # Disable the thing that prints annoying warnings when trying to
    # run manually patchelfed binaries
    environment.stub-ld.enable = false;

    # Enable yggdrasil network.
    services.yggdrasil = {
      enable = true;
      persistentKeys = true;
      settings.IfName = "ygg0";
    };

    programs = {
      fish.enable = true;
      mosh.enable = true;
      ssh.startAgent = true;
    };

    # Automatically collect garbage from the Nix store.
    services.depot.automatic-gc = {
      enable = true;
      interval = "1 hour";
      diskThreshold = 16; # GiB
      maxFreed = 50; # GiB
      preserveGenerations = "14d";
    };
  };
}
