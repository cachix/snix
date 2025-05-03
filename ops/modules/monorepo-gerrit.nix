# Gerrit configuration for the snix monorepo
{ depot, pkgs, config, lib, ... }:

let
  cfg = config.services.gerrit;

  gerritPackage = depot.third_party.nix-gerrit.gerrit_3_11;
  gerritPlugins = depot.third_party.nix-gerrit.plugins_3_11;

  besadiiWithConfig = name: pkgs.writeShellScript "besadii-gerrit01" ''
    export BESADII_CONFIG=/run/agenix/gerrit-besadii-config
    exec -a ${name} ${depot.ops.besadii}/bin/besadii "$@"
  '';

  gerritHooks = pkgs.runCommand "gerrit-hooks" { } ''
    mkdir -p $out
    ln -s ${besadiiWithConfig "change-merged"} $out/change-merged
    ln -s ${besadiiWithConfig "patchset-created"} $out/patchset-created
  '';
in
{
  networking.firewall.allowedTCPPorts = [ 29418 ];
  services.gerrit = {
    enable = true;
    listenAddress = "[::]:4778"; # 4778 - grrt
    serverId = "b4813230-0b9b-46cb-b400-dcbed70f87e6";

    builtinPlugins = [
      "download-commands"
      "hooks"
      "replication"
    ];

    plugins = with gerritPlugins; [
      code-owners
      oauth
      # depot.ops.gerrit-tvl # #118
    ];

    package = gerritPackage;

    jvmHeapLimit = "4g";

    # WARN(raito): keep this synchronized with the Gerrit version!
    jvmPackage = pkgs.openjdk21_headless;

    jvmOpts = [
      # https://bugs.openjdk.org/browse/JDK-8170568 someday… !
      "-Djava.net.preferIPv6Addresses=system"
    ];

    settings = {
      core.packedGitLimit = "100m";
      log.jsonLogging = true;
      log.textLogging = false;
      sshd.advertisedAddress = "cl.snix.dev:29418";
      hooks.path = "${gerritHooks}";
      cache.web_sessions.maxAge = "3 months";
      plugins.allowRemoteAdmin = false;
      change.enableAttentionSet = true;
      change.enableAssignee = false;

      # Configures gerrit for being reverse-proxied by nginx as per
      # https://gerrit-review.googlesource.com/Documentation/config-reverseproxy.html
      gerrit = {
        canonicalWebUrl = "https://cl.snix.dev";
        docUrl = "/Documentation";
      };

      httpd.listenUrl = "proxy-https://${cfg.listenAddress}";

      download.command = [
        "checkout"
        "cherry_pick"
        "format_patch"
        "pull"
      ];

      # Configure for cgit.
      # gitweb = {
      #   type = "custom";
      #   url = "https://code.snix.dev";
      #   project = "/";
      #   revision = "/commit/?id=\${commit}";
      #   branch = "/log/?h=\${branch}";
      #   tag = "/tag/?h=\${tag}";
      #   roottree = "/tree/?h=\${commit}";
      #   file = "/tree/\${file}?h=\${commit}";
      #   filehistory = "/log/\${file}?h=\${branch}";
      #   linkname = "cgit";
      # };

      # # Auto-link panettone bug links
      # commentlink.panettone = {
      #   match = "b/(\\d+)";
      #   link = "https://b.tvl.fyi/issues/$1";
      # };

      commentlink = {
        # Auto-link other CLs
        gerrit = {
          match = "cl/(\\d+)";
          link = "https://cl.snix.dev/q/$1";
        };

        # Auto-link Forgejo issues
        forgejo = {
          match = "#(\\d+)";
          link = "https://git.snix.dev/snix/snix/issues/$1";
        };
      };

      # Configures integration with Keycloak, which then integrates with a
      # variety of backends.
      auth.type = "OAUTH";
      plugin.gerrit-oauth-provider-keycloak-oauth = {
        root-url = "https://auth.snix.dev/";
        realm = "snix-project";
        client-id = "gerrit";
        # client-secret is set in /var/lib/gerrit/etc/secure.config.
      };

      plugin.code-owners = {
        # A Code-Review +2 vote is required from a code owner.
        requiredApproval = "Code-Review+2";
        # The OWNERS check can be overriden using an Owners-Override vote.
        overrideApproval = "Owners-Override+1";
        # People implicitly approve their own changes automatically.
        enableImplicitApprovals = "TRUE";
      };

      # Allow users to add additional email addresses to their accounts.
      oauth.allowRegisterNewEmail = true;

      # Use Gerrit's built-in HTTP passwords, rather than trying to use the
      # password against the backing OAuth provider.
      auth.gitBasicAuthPolicy = "HTTP";

      # Email sending (emails are relayed via the tazj.in domain's
      # GSuite currently).
      #
      # Note that sendemail.smtpPass is stored in
      # $site_path/etc/secure.config and is *not* controlled by Nix.
      #
      # Receiving email is not currently supported.
      sendemail = {
        enable = true;
        html = true; # multi-part, both html and plaintext
        connectTimeout = "10sec";
        from = "Snix Code Review <gerrit@snix.dev>";
        includeDiff = true;
        smtpEncryption = "tls";
        smtpServer = "smtp.postmarkapp.com";
        smtpUser = "PM-T-snix-gerrit-2reTInskye8FLoYt11_";
        smtpServerPort = 2525;
      };
    };

    # Replication of the snix repository to secondary machines, for
    # serving forgejo.
    replicationSettings = {
      gerrit.replicateOnStartup = true;

      # Replicate to our forgejo instance.
      remote.forgejo = {
        url = "git@git.snix.dev:snix/snix.git";
        push = [
          "+refs/heads/*:refs/heads/*"
          "+refs/tags/*:refs/tags/*"
          "+refs/r/*:refs/r/*"
        ];
        timeout = 30;
        threads = 3;
        remoteNameStyle = "dash";
        mirror = true;
        # we are unsure if this should be private info
        replicatePermissions = false;
        projects = [ "snix" ];
      };
    };
  };

  systemd.services.gerrit = {
    serviceConfig = {
      # There seems to be no easy way to get `DynamicUser` to play
      # well with other services (e.g. by using SupplementaryGroups,
      # which seem to have no effect) so we force the DynamicUser
      # setting for the Gerrit service to be disabled and reuse the
      # existing 'git' user.
      DynamicUser = lib.mkForce false;
      User = "git";
      Group = "git";
    };
  };

  # Taken from Lix.
  # Before starting gerrit, we'll want to create a "secure auth" file that contains our secrets.
  systemd.services.gerrit-keys = {
    enable = true;

    before = [ "gerrit.service" ];
    wantedBy = [ "gerrit.service" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = "true";
      WorkingDirectory = "/var/lib/gerrit";
    };

    path = [ pkgs.git ];

    script = ''
      CONF=etc/secure.config

      # Ensure our config file is accessible to gerrit.
      touch $CONF
      chmod 600 $CONF

      # Configure the SSH replication material
      mkdir -p /var/lib/git/.ssh
      cp ${config.age.secrets.gerrit-replication-key.path} /var/lib/git/.ssh/id_replication
      cat > /var/lib/git/.ssh/config <<EOF
      Host *
        IdentityFile /var/lib/git/.ssh/id_replication
      EOF
      chmod 600 /var/lib/git/.ssh/id_replication
      chmod 600 /var/lib/git/.ssh/config
      chmod 700 /var/lib/git/.ssh
      cp -L /etc/ssh/ssh_known_hosts /var/lib/git/.ssh/known_hosts
      chmod 600 /var/lib/git/.ssh/known_hosts
      chown -R git:git /var/lib/git/.ssh

      # ... and finally, plop our secrets inside, and give the file to gerrit.
      git config -f $CONF plugin.gerrit-oauth-provider-keycloak-oauth.client-secret \
        "$(cat ${config.age.secrets.gerrit-oauth-secret.path})"
      git config -f $CONF sendemail.smtpPass \
        "$(cat ${config.age.secrets.gerrit-sendemail-smtp-pass.path})"

      chown git:git $CONF
    '';
  };

  services.depot.restic = {
    paths = [ "/var/lib/gerrit" ];
    exclude = [ "/var/lib/gerrit/tmp" ];
  };
}
