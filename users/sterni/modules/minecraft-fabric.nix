# Declarative, but low Nix module for a modded minecraft server using the
# fabric mod loader. That is to say, the build of the final server JAR
# is not encapsulated in a derivation.
#
# The module has the following interesting properties:
#
#   * The fabric installer is executed on each server startup to assemble the
#     patched server.jar. This is unfortunately necessary, as it seems to be
#     difficult to do so in a derivation (fabric-installer accesses the network,
#     the build doesn't seem to be reproducible). At least this avoids the
#     question of the patched jar's redistributability.
#   * RCON is used for starting and stopping which should prevent data loss,
#     since we can issue a manual save command.
#   * The entire runtime directory of the server is assembled from scratch on
#     each start, so only blessed state (like the world) and declarative
#     configuration (whitelist.json, server.properties, ...) survive.
#   * It supports more than one server running on the same machine.
#
# Missing features:
#
#   * Support for bans
#   * Support for mutable whitelist, ops, …
#   * Op levels
#
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2022-2024 sterni <sternenseemann@systemli.org>

{ lib, pkgs, config, depot, ... }:

let
  #
  # Dependencies
  #
  inherit (depot.nix.utils) storePathName;
  inherit (depot.nix) getBins;

  bins = getBins pkgs.mcrcon [ "mcrcon" ]
    // getBins pkgs.jre [ "java" ]
    // getBins pkgs.diffutils [ "diff" ]
    // getBins pkgs.moreutils [ "sponge" ]
    // getBins pkgs.extrace [ "pwait" ]
    // getBins pkgs.util-linux [ "flock" ];

  #
  # Needed JARs
  #
  fetchJar = { pname, version, url, sha256, passthru ? { } }:
    pkgs.fetchurl {
      name = "${pname}-${version}.jar";
      inherit url sha256;
      passthru = passthru // { inherit version; };
    };

  fabricInstallerJar =
    fetchJar rec {
      pname = "fabric-installer";
      version = "1.0.0";
      url = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${version}/fabric-installer-${version}.jar";
      sha256 = "0yrlzly1g5a80df27jvrbhxbp10xqxfyk64q0s0j13kz78fmnzkx";
    };

  # log4j workaround for Minecraft Server >= 1.12 && < 1.17
  log4jFix_112_116 = pkgs.fetchurl {
    url = "https://launcher.mojang.com/v1/objects/02937d122c86ce73319ef9975b58896fc1b491d1/log4j2_112-116.xml";
    sha256 = "1paha357xbaffl38ckzgdh4l5iib2ydqbv7jsg67nj31nlalclr9";
  };

  serverJars = {
    # Manually updated list of known minecraft `server.jar`s for now.
    # Making this comprehensive isn't that interesting for now, since the module
    # is annoying to use outside of depot anyways as it uses //nix.
    "1.16.5" = fetchJar {
      pname = "server";
      version = "1.16.5";
      url = "https://launcher.mojang.com/v1/objects/1b557e7b033b583cd9f66746b7a9ab1ec1673ced/server.jar";
      sha256 = "19ix6x5ij4jcwqam1dscnqwm0m251gysc2j793wjcrb9sb3jkwsq";
      passthru = {
        baseJvmOpts = [
          "-Dlog4j.configurationFile=${log4jFix_112_116}"
        ];
      };
    };
    "1.17" = fetchJar {
      pname = "server";
      version = "1.17";
      url = "https://launcher.mojang.com/v1/objects/0a269b5f2c5b93b1712d0f5dc43b6182b9ab254e/server.jar";
      sha256 = "0jqz7hpx7zvjj2n5rfrh8jmdj6ziqyp8c9nq4sr4jmkbky6hsfbv";
      passthru.baseJvmOpts = [
        "-Dlog4j2.formatMsgNoLookups=true"
      ];
    };
    "1.17.1" = fetchJar {
      pname = "server";
      version = "1.17.1";
      url = "https://launcher.mojang.com/v1/objects/a16d67e5807f57fc4e550299cf20226194497dc2/server.jar";
      sha256 = "0pzmzagvrrapjsnd8xg4lqwynwnb5rcqk2n9h2kzba8p2fs13hp8";
      passthru.baseJvmOpts = [
        "-Dlog4j2.formatMsgNoLookups=true"
      ];
    };
    "1.18" = fetchJar {
      pname = "server";
      version = "1.18";
      url = "https://launcher.mojang.com/v1/objects/3cf24a8694aca6267883b17d934efacc5e44440d/server.jar";
      sha256 = "0vvycjcfq96z7cl5dsrq98k9b7j7l4x0y9nflrcqmcvink7fs5w4";
      passthru.baseJvmOpts = [
        "-Dlog4j2.formatMsgNoLookups=true"
      ];
    };
    "1.18.1" = fetchJar {
      pname = "server";
      version = "1.18.1";
      url = "https://launcher.mojang.com/v1/objects/125e5adf40c659fd3bce3e66e67a16bb49ecc1b9/server.jar";
      sha256 = "1pyvym6xzjb1siizzj4ma7lpb05qhgxnzps8lmlbk00lv0515kgb";
    };
    "1.18.2" = fetchJar {
      pname = "server";
      version = "1.18.2";
      url = "https://launcher.mojang.com/v1/objects/c8f83c5655308435b3dcf03c06d9fe8740a77469/server.jar";
      sha256 = "0hx330bnadixph44sip0h5h986m11qxbdba6lbgwz4da6lg9vgjp";
    };
    "1.19" = fetchJar {
      pname = "server";
      version = "1.19";
      url = "https://launcher.mojang.com/v1/objects/e00c4052dac1d59a1188b2aa9d5a87113aaf1122/server.jar";
      sha256 = "1cnjrqr2vn8gppd1y1lcdrc46fd7m1b3zl28zpbw72fgy1bd1vyy";
    };
    "1.19.1" = fetchJar {
      pname = "server";
      version = "1.19.1";
      url = "https://piston-data.mojang.com/v1/objects/8399e1211e95faa421c1507b322dbeae86d604df/server.jar";
      sha256 = "0jnlb5z8a7qi6p6bbwnmdl77b8kq83ryfdp58dhx8kg2hf6lbfx8";
    };
    "1.19.2" = fetchJar {
      pname = "server";
      version = "1.19.2";
      url = "https://piston-data.mojang.com/v1/objects/f69c284232d7c7580bd89a5a4931c3581eae1378/server.jar";
      sha256 = "15jdxh5zvsgvvk9hnv47swgjfg8fr653g6nx99q1rxpmkq32frxj";
    };
    "1.19.3" = fetchJar {
      pname = "server";
      version = "1.19.3";
      url = "https://piston-data.mojang.com/v1/objects/c9df48efed58511cdd0213c56b9013a7b5c9ac1f/server.jar";
      sha256 = "06qykz3nq7qmfw4phs3wvq3nk28clg8s3qrs37856aai8b8kmgaf";
    };
    # Starting with 1.19.4 we could use --pidFile for systemd's PIDFile=, but as
    # the service doesn't fork, there seems to be no point.
    "1.19.4" = fetchJar {
      pname = "server";
      version = "1.19.4";
      url = "https://piston-data.mojang.com/v1/objects/8f3112a1049751cc472ec13e397eade5336ca7ae/server.jar";
      sha256 = "0lrzpqd6zjvqh9g2byicgh66n43z0hwzp863r22ifx2hll6s2955";
    };
    # https://feedback.minecraft.net/hc/en-us/articles/16499677456781-Minecraft-Java-Edition-1-20-Trails-Tales
    "1.20" = fetchJar {
      name = "server";
      version = "1.20";
      url = "https://piston-data.mojang.com/v1/objects/15c777e2cfe0556eef19aab534b186c0c6f277e1/server.jar";
      sha256 = "0sym07vqrlbhyxxhlpz73ls0jh0g9qcl4plaa1scx0n1rr1cahgz";
    };
    # https://www.minecraft.net/en-us/article/minecraft--java-edition-1-20-1
    "1.20.1" = fetchJar {
      pname = "server";
      version = "1.20.1";
      url = "https://piston-data.mojang.com/v1/objects/84194a2f286ef7c14ed7ce0090dba59902951553/server.jar";
      sha256 = "1q3r3c95vkai477r3gsmf2p0pmyl4zfn0qwl8y0y60m1qnfkmxrs";
    };
    # https://www.minecraft.net/en-us/article/minecraft-java-edition-1-20-2
    "1.20.2" = fetchJar {
      pname = "server";
      version = "1.20.2";
      url = "https://piston-data.mojang.com/v1/objects/5b868151bd02b41319f54c8d4061b8cae84e665c/server.jar";
      sha256 = "1s7ag1p8v0vyzc6a8mjkd3rcf065hjb4avqa3zj4dbb9hn1y9bhx";
    };
    # https://www.minecraft.net/en-us/article/minecraft-java-edition-1-20-3
    "1.20.3" = fetchJar {
      pname = "server";
      version = "1.20.3";
      url = "https://piston-data.mojang.com/v1/objects/4fb536bfd4a83d61cdbaf684b8d311e66e7d4c49/server.jar";
      sha256 = "1blb2cp1nlm0yr7yjhazj33g0hjlgfawx2v7y16h70pijfz8kv9n";
    };
    # https://www.minecraft.net/en-us/article/minecraft-java-edition-1-20-4
    "1.20.4" = fetchJar {
      pname = "server";
      version = "1.20.4";
      url = "https://piston-data.mojang.com/v1/objects/8dd1a28015f51b1803213892b50b7b4fc76e594d/server.jar";
      sha256 = "0qykf9a3nacklqsyb30kg9m79nw462la6rf92gsdssdakprscgy0";
    };
    # https://www.minecraft.net/en-us/article/minecraft-java-edition-1-21
    # Has a known exploit, fixed in 1.21.1
    "1.21" = fetchJar {
      pname = "server";
      version = "1.21";
      url = "https://piston-data.mojang.com/v1/objects/450698d1863ab5180c25d7c804ef0fe6369dd1ba/server.jar";
      sha256 = "0gzmpifl6l1cq11lpjd5gadw50095wgyxlm2gkpzkngrhvd98qy9";
    };
    # https://www.minecraft.net/en-us/article/minecraft-java-edition-1-21-1
    "1.21.1" = fetchJar {
      pname = "server";
      version = "1.21.1";
      url = "https://piston-data.mojang.com/v1/objects/59353fb40c36d304f2035d51e7d6e6baa98dc05c/server.jar";
      sha256 = "1fxl66938ixks6imz8c5bry69z0kh6iawq1fiwca1kck7rlmbg73";
    };
  };

  #
  # mods directory for fabric
  #
  makeModFolder = name: mods:
    pkgs.runCommand "${name}-fabric-mod-folder" { } (
      ''
        mkdir -p "$out"
      '' + lib.concatMapStrings
        (mod: ''
          test -f "${mod}" || {
              printf 'Not a regular file: %s\n' "${mod}" >&2
              exit 1
          }
          ln -s "${mod}" "$out/${storePathName mod}"
        '')
        mods
    );

  #
  # Create a server.properties file
  #
  propertyValue = v:
    if builtins.isBool v
    then lib.boolToString v
    else toString v;

  serverPropertiesFile = name: instanceCfg:
    let
      serverProperties' =
        builtins.removeAttrs instanceCfg.serverProperties [
          "rcon.password"
        ] // {
          enable-rcon = true;
        };
    in
    pkgs.writeText "${name}-server.properties" (''
      # created by minecraft-fabric.nix
    '' + lib.concatStrings (lib.mapAttrsToList
      (key: value: ''
        ${key}=${propertyValue value}
      '')
      serverProperties'));

  #
  # Create JSON “state” files
  #
  writeJson = name: data: pkgs.writeText "${name}.json" (builtins.toJSON data);

  toWhitelist = name: uuid: { inherit name uuid; };

  whitelistFile = name: instanceCfg:
    writeJson "${name}-whitelist" (
      lib.mapAttrsToList toWhitelist instanceCfg.whitelist
    );

  opsFile = name: instanceCfg:
    writeJson "${name}-ops" (
      lib.mapAttrsToList
        (name: value:
          toWhitelist name value // {
            level = 4;
            bypassesPlayerLimit = true;
          }
        )
        instanceCfg.ops
    );

  #
  # Service start and stop scripts
  #
  stopScript = name: instanceCfg:
    pkgs.writeShellScript "minecraft-fabric-${name}-stop" ''
      set -eu

      # Before shutting down, display the diff between prescribed and used
      # server.properties file for debugging purposes; filter out credential
      actualProperties="''${RUNTIME_DIRECTORY}/server.properties"
      sort "$actualProperties" | ${bins.sponge} "$actualProperties"
      ( ${bins.diff} -u "${serverPropertiesFile name instanceCfg}" \
          "$actualProperties" \
          || true ) | grep -v rcon.password

      export MCRCON_HOST=localhost
      export MCRCON_PORT=${lib.escapeShellArg instanceCfg.serverProperties."rcon.port"}
      # Unfortunately, mcrcon can't read the password from a file
      export MCRCON_PASS="$(cat "''${RCON_PASSWORD}")"

      # Send stop request
      "${bins.mcrcon}" 'say Server is stopping' save-all stop

      # Wait for service to come down (systemd SIGTERMs right after ExecStop)
      "${bins.flock}" "''${RUNTIME_DIRECTORY}" true
    '';

  startScript = name: instanceCfg:
    let
      serverJar = serverJars.${instanceCfg.version} or
        (throw "Don't have server.jar for Minecraft Server ${instanceCfg.version}");

    in

    pkgs.writeShellScript "minecraft-fabric-${name}-start" ''
      set -eu

      cd "''${RUNTIME_DIRECTORY}"

      copyFromStore() {
          install -m600 "$1" "$2"
      }

      # Check if world is available
      if test ! -d "${instanceCfg.world}"; then
          echo "Could not find world, generating new one" >&2
          mkdir -p "${instanceCfg.world}"
      fi

      # Put required files into place
      echo eula=true > eula.txt
      ln -s "${instanceCfg.world}" "${instanceCfg.level-name or "world"}"
      copyFromStore "${serverJar}" server.jar
      copyFromStore "${whitelistFile name instanceCfg}" whitelist.json
      copyFromStore "${opsFile name instanceCfg}" ops.json
      ln -s "${makeModFolder name instanceCfg.mods}" mods

      # Create config and set password from credentials (echo hopefully doesn't leak)
      copyFromStore "${serverPropertiesFile name instanceCfg}" server.properties
      echo "rcon.password=$(cat "$RCON_PASSWORD")" >> server.properties

      # Build patched jar
      "${bins.java}" -jar "${fabricInstallerJar}" \
          server -mcversion "${instanceCfg.version}"

      # Lock is held as long as the server is running, so that we can wait for
      # the actual shutdown in the stop script without relying on $MAINPID.
      exec "${bins.flock}" "''${RUNTIME_DIRECTORY}" \
          "${bins.java}" \
          ${lib.escapeShellArgs (serverJar.baseJvmOpts or [ ] ++ instanceCfg.jvmOpts)} \
          -jar fabric-server-launch.jar nogui
    '';

  #
  # Option types
  #
  impurePath = lib.types.path // {
    name = "impurePath";
    check = x:
      lib.types.path.check x
        && !(builtins.isPath x)
        && !(lib.hasPrefix builtins.storeDir (toString x));
  };


  instanceType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Minecraft server instance with the fabric mod loader";

      version = lib.mkOption {
        type = lib.types.str;
        description = "Minecraft Server version to use.";
        example = "1.16.5";
      };

      mods = lib.mkOption {
        type = with lib.types; listOf package;
        description = "List of fabric mod JARs to load.";
        default = [ ];
      };

      world = lib.mkOption {
        type = impurePath;
        description = "Path to the Minecraft world folder to use.";
        example = "/var/minecraft/world";
      };

      jvmOpts = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "-Xmx2048M"
          "-Xms2048M"
        ];
        description = ''
          Options to pass to
          <citerefentry>
            <refentrytitle>java</refentrytitle>
            <manvolnum>1</manvolnum>
          </citerefentry>
          in order to tweak the runtime of the JVM.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "minecraft";
        description = ''
          Name of an existing user to run the server as. Needs to have write
          access to the specified world.
        '';
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = ''
          Name of an existing group to run the server under.
        '';
      };

      rconPasswordFile = lib.mkOption {
        type = impurePath;
        description = ''
          File (outised the store) that stores the password to use for Minecraft's
          RCON interface.
        '';
        example = "/var/secrets/minecraft-rcon";
      };

      whitelist = lib.mkOption {
        type = with lib.types; attrsOf str;
        description = ''
          Attribute set mapping whitelisted user names to their user ids.
        '';
        example = {
          sternenseemann = "d8e48069-1905-4886-a5da-a4ee917ee254";
        };
      };

      ops = lib.mkOption {
        type = with lib.types; attrsOf str;
        description = ''
          Attribute set mapping op-ed user names to their user ids.
          Setting permission levels is not possible at the moment,
          set to 4 by default.
        '';
        example = {
          sternenseemann = "d8e48069-1905-4886-a5da-a4ee917ee254";
        };
      };

      serverProperties = lib.mkOption {
        type = lib.types.submodule {
          freeformType = lib.types.attrs;

          # Only options the module needs to access are declared explicitly
          options = {
            server-port = lib.mkOption {
              type = lib.types.port;
              default = 25565;
              description = ''
                Port to listen on.
              '';
            };

            "rcon.port" = lib.mkOption {
              type = lib.types.port;
              default = 25575;
              description = ''
                Port to use for the RCON control mechanism.
              '';
            };
          };
        };
      };
    };
  };

  cfg = config.services.minecraft-fabric-server;

  serverPorts = lib.mapAttrsToList
    (_: instanceCfg:
      instanceCfg.serverProperties.server-port
    )
    cfg;

  rconPorts = lib.mapAttrsToList
    (_: instanceCfg:
      instanceCfg.serverProperties."rcon.port"
    )
    cfg;
in

{
  options = {
    services.minecraft-fabric-server = lib.mkOption {
      type = with lib.types; attrsOf instanceType;
      default = { };
      description = "Minecraft server instances with the fabric mod loader";
    };
  };

  config = {
    assertions = [
      {
        assertion = builtins.all (instance: !instance.enable) (builtins.attrValues cfg)
          || pkgs.config.allowUnfreeRedistributable or false
          || pkgs.config.allowUnfree or false;
        message = lib.concatStringsSep " " [
          "You need to allow unfree software for minecraft,"
          "as you'll implicitly agree to Mojang's EULA."
        ];
      }
      {
        assertion =
          let
            allPorts = serverPorts ++ rconPorts;
          in
          lib.unique allPorts == allPorts;
        message = "All assigned ports need to be unique.";
      }
    ];

    systemd.services = lib.mapAttrs'
      (name: instanceCfg:
        {
          name = "minecraft-fabric-${name}";
          value = {
            description = "Minecraft server ${name} with the fabric mod loader";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            inherit (instanceCfg) enable;

            environment = {
              # Workaround for https://github.com/systemd/systemd/issues/34805
              "RCON_PASSWORD" = "%d/rcon-password";
            };

            serviceConfig = {
              Type = "exec";
              User = instanceCfg.user;
              Group = instanceCfg.group;
              ExecStart = startScript name instanceCfg;
              ExecStop = stopScript name instanceCfg;
              RuntimeDirectory = "minecraft-fabric-${name}";
              LoadCredential = "rcon-password:${instanceCfg.rconPasswordFile}";
              RestartSec = "40s";
            };
          };
        }
      )
      cfg;

    networking.firewall = {
      allowedTCPPorts = serverPorts;
      allowedUDPPorts = serverPorts;
    };
  };
}
