# Run the Telegram<>IRC sync bot for the Volga Sprint channel.
#
# This module is written in a pretty ad-hoc style, as it is sort of a
# throwaway thing (will be removed again after the event).
{ depot, config, lib, pkgs, ... }:

let
  cfg = config.services.depot.teleirc;
  description = "IRC<>Telegram sync for Volga Sprint channel";
  configFile = builtins.toFile "teleirc.env" ''
    # connect through tvlbot's ZNC bouncer
    IRC_SERVER="localhost"
    IRC_PORT=2627
    IRC_USE_SSL=false
    IRC_CHANNEL="#volgasprint"
    IRC_BLACKLIST="tvlbot"
    IRC_BOT_NAME="tvlbot"
    IRC_BOT_REALNAME="TVL bot for Volga Sprint"
    IRC_BOT_IDENT="tvlbot"
    IRC_SEND_STICKER_EMOJI=false # look into this
    TELEGRAM_CHAT_ID=-1002153072030
  '';
in
{
  options.services.depot.teleirc.enable = lib.mkEnableOption description;

  config = lib.mkIf cfg.enable {
    systemd.services.teleirc = {
      inherit description;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        DynamicUser = true;
        Restart = "always";
        EnvironmentFile = "/run/agenix/teleirc";
        ExecStart = "${depot.third_party.teleirc}/bin/teleirc -conf ${configFile}";
      };
    };
  };
}
