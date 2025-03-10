# Module that configures CLBot, our Gerrit->IRC info bridge.
{ depot, config, lib, utils, ... }:

let
  inherit (builtins) attrValues concatStringsSep mapAttrs;

  inherit (lib)
    listToAttrs
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types;

  description = "Bot to forward CL notifications";
  cfg = config.services.depot.clbot;

  mkFlags = flags:
    concatStringsSep " "
      (attrValues (mapAttrs (key: value: "-${key} \"${toString value}\"") flags));

  mkUnit = channel: channelFlags: {
    name = "clbot-${utils.escapeSystemdPath channel}";
    value = {
      description = "${description} to ${channel}";
      wantedBy = [ "multi-user.target" ];

      script = "${depot.fun.clbot}/bin/clbot ${mkFlags (cfg.flags // channelFlags // {
        irc_channel = channel;
      })} -alsologtostderr";

      serviceConfig = {
        User = "clbot";
        EnvironmentFile = cfg.secretsFile;
        Restart = "always";
      };
    };
  };
in
{
  options.services.depot.clbot = {
    enable = mkEnableOption description;

    flags = mkOption {
      type = types.attrsOf types.str;
      description = "Key value pairs for command line flags";
    };

    channels = mkOption {
      type = with types; attrsOf (attrsOf str);
      description = "Channels in which to post (generates one unit per channel); nested attrs are used as extra flags to the service, which override the attrs in `flags`";
    };

    secretsFile = mkOption {
      type = types.str;
      description = "EnvironmentFile from which to load secrets";
      default = config.age.secretsDir + "/clbot";
    };
  };

  config = mkIf cfg.enable {
    # This does not use DynamicUser because we need to make some files
    # (notably the SSH private key) readable by this user outside of
    # the module.
    users = {
      groups.clbot = { };

      users.clbot = {
        group = "clbot";
        isSystemUser = true;
      };
    };

    systemd.services = listToAttrs (mapAttrsToList mkUnit cfg.channels);
  };
}
