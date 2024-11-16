{ pkgs, depot, config, ... }:

let
  carpet = pkgs.fetchurl {
    url = "https://github.com/gnembon/fabric-carpet/releases/download/1.4.147/fabric-carpet-1.21-1.4.147+v240613.jar";
    sha256 = "1n8r1zznl2xvkzqqwzg18d0rhfzrb675ik7z22q29svkw2jci7q7";
  };

  carpet-extra = pkgs.fetchurl {
    url = "https://github.com/gnembon/carpet-extra/releases/download/1.4.148/carpet-extra-1.21-1.4.148.jar";
    sha256 = "1yyqv1c08vml3sxyjbs5qk0z3yqiylzq8qa8vxbwiyw49dx5yhnq";
  };

  userGroup = "minecraft";

  makeJvmOpts = megs: [
    "-Xms${toString megs}M"
    "-Xmx${toString megs}M"
  ];

  whitelist = {
    spreadwasser = "242a66eb-2df2-4585-9a28-ac763ad0d0f9";
    sternenseemann = "d8e48069-1905-4886-a5da-a4ee917ee254";
  };

  rconPasswordFile = config.age.secretsDir + "/minecraft-rcon";

  baseProperties = {
    white-list = true;
    allow-flight = true;
    difficulty = "hard";
    function-permission-level = 4;
    snooper-enabled = false;
    # TODO(sterni): replaced (?) by simulation-distance which defaults to 1
    view-distance = 12;
    sync-chunk-writes = "false"; # the single biggest performance fix
    max-tick-time = 6000000; # TODO(sterni): disable watchdog via carpet
    enforce-secure-profile = false;
    # TODO(sterni): set disable pause-when-empty-seconds? we don't have anything in spawn though.
  };
in

{
  imports = [
    ../../modules/minecraft-fabric.nix
    ../../modules/backup-minecraft-fabric.nix
  ];

  config = {
    environment.systemPackages = [
      pkgs.mcrcon
      pkgs.jre
    ];

    users = {
      users."${userGroup}" = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = depot.users.sterni.keys.all;
        shell = "${pkgs.fish}/bin/fish";
      };

      groups."${userGroup}" = { };
    };

    age.secrets = {
      minecraft-rcon.file = depot.users.sterni.secrets."minecraft-rcon.age";
    };

    services.backup-minecraft-fabric-servers = {
      enable = true;
      repository = "/srv/backup/from-local/minecraft";
    };

    services.minecraft-fabric-server = {
      creative = {
        enable = false; # not actively used
        version = "1.21.1";
        mods = [
          carpet
          carpet-extra
        ];
        world = config.users.users.${userGroup}.home + "/worlds/creative";

        jvmOpts = makeJvmOpts 2048;
        user = userGroup;
        group = userGroup;

        inherit whitelist rconPasswordFile;
        ops = whitelist;

        serverProperties = baseProperties // {
          server-port = 25566;
          "rcon.port" = 25576;
          gamemode = "creative";
          enable-command-block = true;
          motd = "storage design server";
          spawn-protection = 2;
        };
      };

      carpet = {
        enable = true;
        version = "1.21.1";
        mods = [
          carpet
          carpet-extra
        ];
        world = config.users.users.${userGroup}.home + "/worlds/carpet";

        jvmOpts = makeJvmOpts 4096;
        user = userGroup;
        group = userGroup;

        inherit whitelist rconPasswordFile;
        ops = whitelist;

        serverProperties = baseProperties // {
          server-port = 25565;
          "rcon.port" = 25575;
          motd = "ich tu fleissig hustlen nenn mich bob der baumeister";

          level-seed = 7240251176989694927; # for posterity
        };
      };
    };
  };
}
