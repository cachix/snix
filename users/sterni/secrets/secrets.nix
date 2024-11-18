let
  nonremote = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJk+KvgvI2oJTppMASNUfMcMkA2G5ZNt+HnWDzaXKLlo"
  ];

  ingeborg = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAHQn/j6NCYucpM7qIEIslVJxiFeUEKa0hi+HobTz/12"
  ];
in

{
  "warteraum-salt.age".publicKeys = nonremote ++ ingeborg;
  "warteraum-tokens.age".publicKeys = nonremote ++ ingeborg;
  "minecraft-rcon.age".publicKeys = nonremote ++ ingeborg;
  "netdata-htpasswd.age".publicKeys = nonremote ++ ingeborg;
}
