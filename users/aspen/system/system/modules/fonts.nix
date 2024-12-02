{ config, lib, pkgs, ... }:
{
  fonts = {
    packages = with pkgs; [
      noto-fonts-emoji
      twitter-color-emoji
      weather-icons
    ] ++ builtins.filter lib.isDerivation (builtins.attrValues pkgs.nerd-fonts);

    fontconfig.defaultFonts.emoji = [ "Twitter Color Emoji" ];
  };
}
