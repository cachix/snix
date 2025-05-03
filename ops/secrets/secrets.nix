# This file is read by agenix standalone, to know which audiences to (re)encrypt secrets to.

let
  raito = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICaw9ihTG7ucB8P38XdalEWev8+q96e2yNm4B+/I9IJp"
  ];

  edef = [
    "age1n8vj5s4s9vyl8cq76q3mxaj5yxhmeuzh3puffp27j59e6vsj9frq34f90r"
  ];

  flokli = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTVTXOutUZZjXLB0lUSgeKcSY/8mxKkC0ingGK1whD2 flokli"
  ];

  gerrit01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN+RCLAExaM5EC70UsCPMtDT1Cfa80Ux/vex95fLk9S4 root@gerrit01";
  public01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICzB7bqXWcv+sVokySvj1d74zRlVLSNqBw7/OY3c7QYd root@public01";
  build01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEteVaeN/FEAY8yyGWdAbv6+X6yv2m8+4F5qZEAhxW9f root@build01";
  meta01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINj2csTShq5PsmB/T0596TASyf7VImD4592HEqaYHgKh root@meta01";

  superadmins = raito ++ edef ++ flokli;

  allDefault.publicKeys = superadmins ++ [ gerrit01 public01 build01 meta01 ];
  terraform.publicKeys = superadmins;
  gerrit01Default.publicKeys = superadmins ++ [ gerrit01 ];
  public01Default.publicKeys = superadmins ++ [ public01 ];
  build01Default.publicKeys = superadmins ++ [ build01 ];
  meta01Default.publicKeys = superadmins ++ [ meta01 ];
  ciDefault.publicKeys = superadmins ++ [ gerrit01 build01 ];
in
{
  "grafana-agent-password.age" = allDefault;

  "restic-repository-password.age" = allDefault;
  "restic-bucket-credentials.age" = allDefault;

  "keycloak-db-password.age" = public01Default;

  "buildkite-api-proxy-token.age" = gerrit01Default;
  "gerrit-oauth-secret.age" = gerrit01Default;
  "gerrit-replication-key.age" = gerrit01Default;
  "gerrit-sendemail-smtp-pass.age" = gerrit01Default;
  "gerrit-autosubmit.age" = gerrit01Default;

  "forgejo-oauth-secret.age" = public01Default;
  "forgejo-smtp-passwd.age" = public01Default;

  "grafana-oauth-secret.age" = public01Default;


  "binary-cache-key.age" = build01Default;
  "buildkite-agent-token.age" = build01Default;
  "buildkite-ssh-private-key.age" = build01Default;
  "buildkite-besadii-config.age" = ciDefault;
  "buildkite-graphql-token.age" = build01Default;

  "metrics-push-htpasswd.age" = meta01Default;
  "alertmanager-irc-relay-environment.age" = meta01Default;
  "mimir-environment.age" = meta01Default;
  "mimir-webhook-url.age" = meta01Default;

  "tf-dns.age" = terraform;
  "tf-keycloak.age" = terraform;
  "tf-hcloud.age" = terraform;
  "tf-hetzner-s3.age" = terraform;
  "tf-buildkite.age" = terraform;
}
