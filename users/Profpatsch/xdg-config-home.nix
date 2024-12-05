{ depot, pkgs, lib, ... }:
depot.nix.writeExecline "xdg-config-home" { } [
  "if"
  "-n"
  [
    "printenv"
    "XDG_CONFIG_HOME"
  ]
  "importas"
  "HOME"
  "HOME"
  "echo"
  "\${HOME}/.config"
]
