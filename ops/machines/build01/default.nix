{ depot, lib, pkgs, ... }: # readTree options
{ config, ... }: # passed by module system
let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    (mod "o11y/agent.nix")
    (mod "snix-buildkite.nix")
    (mod "harmonia.nix")
    (mod "known-hosts.nix")

    (depot.third_party.agenix.src + "/modules/age.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Machine model taken from project Floral.
  boot.isContainer = true;

  # XXX: There's currently no way to remove the "problematic" entries (trying
  # to override the /proc, /sys, /dev, ... mounts from systemd-nspawn) while
  # also keeping the entry for the wrappers dir.
  boot.specialFileSystems = lib.mkForce {
    "/run/wrappers" = {
      fsType = "tmpfs";
      options = [ "nodev" "mode=755" "size=${config.security.wrapperDirSize}" ];
    };
  };

  services.depot.buildkite = {
    enable = true;
    agentCount = 32;
    largeSlots = 32;
  };

  boot.loader.initScript.enable = true;
  system.switch.enableNg = false;
  nix.nrBuildUsers = 256;
  nix.settings.max-jobs = 64;
  nix.gc.automatic = true;
  nix.package = pkgs.lix;
  # Put builds in /var/tmp as it can be quite big and would cause spurious
  # failures from time to time: https://git.snix.dev/snix/snix/issues/82
  nix.settings.build-dir = "/var/tmp";

  networking = {
    useNetworkd = true;
    useHostResolvConf = false;

    hostName = "build01";
    domain = "infra.snix.dev";
    nameservers = [
      "2001:4860:4860::6464"
      "2001:4860:4860::64"
    ];

    interfaces.host0.ipv6 = {
      addresses = [
        { address = "2001:bc8:38ee:100:7000::20"; prefixLength = 64; }
      ];
      routes = [
        { address = "64:ff9b::"; via = "2001:bc8:38ee:100::100"; prefixLength = 96; }
      ];
    };

    nftables.enable = true;
    firewall = {
      extraInputRules = ''
        # Allow public01 to access Harmonia
        ip6 saddr { 2a01:4f8:c013:3e62::1 } tcp dport { 5000 } accept
        ip saddr { 49.13.70.233 } tcp dport { 5000 } accept
      '';
      allowPing = true;
    };
  };

  age.secrets =
    let
      secretFile = name: depot.ops.secrets."${name}.age";
    in
    {
      buildkite-agent-token = {
        file = secretFile "buildkite-agent-token";
        mode = "0440";
        group = "buildkite-agents";
      };
      buildkite-private-key = {
        file = secretFile "buildkite-ssh-private-key";
        mode = "0440";
        group = "buildkite-agents";
      };
      buildkite-besadii-config = {
        file = secretFile "buildkite-besadii-config";
        mode = "0440";
        group = "buildkite-agents";
      };
      buildkite-graphql-token = {
        file = secretFile "buildkite-graphql-token";
        mode = "0440";
        group = "buildkite-agents";
      };
    };
  systemd.tmpfiles.rules = [
    "d '/nix/var/nix/gcroots/buildkite' 0770 - buildkite-agents - -"
    "z '/nix/var/nix/gcroots' 0771 - - - -"
  ];

  services.openssh.enable = true;
  time.timeZone = "UTC";
  users.users.root.openssh.authorizedKeys.keys = depot.ops.users.edef ++ depot.ops.users.flokli ++ depot.ops.users.raito;
  users.groups.kvm = { };
  users.users.root.extraGroups = [ "kvm" ];

  system.stateVersion = "25.05";
}
