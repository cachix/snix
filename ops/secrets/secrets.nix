let
  tazjin = [
    # tverskoy
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM1fGWz/gsq+ZeZXjvUrV+pBlanw1c3zJ9kLTax9FWQy"

    # zamalek
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDBRXeb8EuecLHP0bW4zuebXp4KRnXgJTZfeVWXQ1n1R"

    # khamovnik
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID1ptE5HvGSXxSXo+aHBTKa5PBlAM1HqmpzWz0yAhHLj"

    # arbat
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1Eai0p7eF7XML5wokqF4GlVZM+YXEORfs/GPGwEky7"
  ];

  aspen = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMcBGBoWd5pPIIQQP52rcFOQN3wAY0J/+K2fuU6SffjA "
  ];

  sterni = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJk+KvgvI2oJTppMASNUfMcMkA2G5ZNt+HnWDzaXKLlo"
  ];

  flokli = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTVTXOutUZZjXLB0lUSgeKcSY/8mxKkC0ingGK1whD2 flokli";

  sanduny = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOag0XhylaTVhmT6HB8EN2Fv5Ymrc4ZfypOXONUkykTX";
  whitby = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILNh/w4BSKov0jdz3gKBc98tpoLta5bb87fQXWBhAl2I";
  nevsky = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHQe7M+G8Id3ZD7j+I07TCUV1o12q1vpsOXHRlcPSEfa";
  bugry = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGqG6sITyJ/UsQ/RtYqmmMvTT4r4sppadoQIz5SvA+5J";

  admins = tazjin ++ aspen ++ sterni;
  allHosts = [ whitby sanduny nevsky bugry ];
  for = hosts: {
    publicKeys = hosts ++ admins;
  };
in
{
  "besadii.age" = for [ whitby nevsky ];
  "buildkite-agent-token.age" = for [ whitby nevsky ];
  "buildkite-graphql-token.age" = for [ whitby nevsky ];
  "buildkite-ssh-private-key.age" = for [ whitby nevsky ];
  "clbot-ssh.age" = for [ whitby nevsky ];
  "clbot.age" = for [ whitby nevsky ];
  "depot-inbox-imap.age" = for [ sanduny ];
  "depot-replica-key.age" = for [ whitby nevsky ];
  "gerrit-autosubmit.age" = for [ whitby nevsky ];
  "gerrit-secrets.age" = for [ whitby nevsky ];
  "grafana.age" = for [ whitby nevsky ];
  "irccat.age" = for [ whitby nevsky ];
  "journaldriver.age" = for allHosts;
  "keycloak-db.age" = for [ whitby nevsky ];
  "nix-cache-priv.age" = for [ whitby nevsky ];
  "nix-cache-pub.age" = for [ whitby nevsky ];
  "owothia.age" = for [ whitby nevsky ];
  "panettone.age" = for [ whitby nevsky ];
  "smtprelay.age" = for [ whitby nevsky ];
  "teleirc.age" = for [ whitby nevsky ];
  "tf-buildkite.age" = for [ /* humans only */ ];
  "tf-glesys.age" = for [ /* humans only */ ];
  "tf-keycloak.age" = for [ flokli ];
  "tvl-alerts-bot-telegram-token.age" = for [ whitby nevsky ];
  "wg-bugry.age" = for [ bugry ];
  "wg-nevsky.age" = for [ nevsky ];
}
