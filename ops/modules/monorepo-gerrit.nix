# Gerrit configuration for the TVL monorepo
{ depot, pkgs, config, lib, ... }:

let
  cfg = config.services.gerrit;

  besadiiWithConfig = name: pkgs.writeShellScript "besadii-whitby" ''
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
  services.gerrit = {
    enable = true;
    listenAddress = "[::]:4778"; # 4778 - grrt
    serverId = "4fdfa107-4df9-4596-8e0a-1d2bbdd96e36";

    builtinPlugins = [
      "download-commands"
      "hooks"
      "replication"
    ];

    plugins = with depot.third_party.gerrit_plugins; [
      code-owners
      oauth
      depot.ops.gerrit-tvl
    ];

    package = depot.third_party.gerrit;

    jvmHeapLimit = "4g";

    # In some NixOS channel bump, the default version of OpenJDK has
    # changed to one that is incompatible with our current version of
    # Gerrit.
    #
    # TODO(tazjin): Update Gerrit and remove this when possible.
    jvmPackage = pkgs.openjdk17_headless;

    settings = {
      core.packedGitLimit = "100m";
      log.jsonLogging = true;
      log.textLogging = false;
      sshd.advertisedAddress = "code.tvl.fyi:29418";
      hooks.path = "${gerritHooks}";
      cache.web_sessions.maxAge = "3 months";
      plugins.allowRemoteAdmin = false;
      change.enableAttentionSet = true;
      change.enableAssignee = false;

      # Configures gerrit for being reverse-proxied by nginx as per
      # https://gerrit-review.googlesource.com/Documentation/config-reverseproxy.html
      gerrit = {
        canonicalWebUrl = "https://cl.tvl.fyi";
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
      gitweb = {
        type = "custom";
        url = "https://code.tvl.fyi";
        project = "/";
        revision = "/commit/?id=\${commit}";
        branch = "/log/?h=\${branch}";
        tag = "/tag/?h=\${tag}";
        roottree = "/tree/?h=\${commit}";
        file = "/tree/\${file}?h=\${commit}";
        filehistory = "/log/\${file}?h=\${branch}";
        linkname = "cgit";
      };

      # Auto-link panettone bug links
      commentlink.panettone = {
        match = "b/(\\d+)";
        link = "https://b.tvl.fyi/issues/$1";
      };

      # Auto-link other CLs
      commentlink.gerrit = {
        match = "cl/(\\d+)";
        link = "https://cl.tvl.fyi/$1";
      };

      # Auto-link links to monotonically increasing revisions/commits
      commentlink.revision = {
        match = "r/(\\d+)";
        link = "https://code.tvl.fyi/commit/?h=refs/r/$1";
      };

      # Configures integration with Keycloak, which then integrates with a
      # variety of backends.
      auth.type = "OAUTH";
      plugin.gerrit-oauth-provider-keycloak-oauth = {
        root-url = "https://auth.tvl.fyi/auth";
        realm = "TVL";
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
        html = false;
        connectTimeout = "10sec";
        from = "TVL Code Review <tvlbot@tazj.in>";
        includeDiff = true;
        smtpEncryption = "none";
        smtpServer = "localhost";
        smtpServerPort = 2525;
      };
    };

    # Replication of the depot repository to secondary machines, for
    # serving cgit/josh.
    replicationSettings = {
      gerrit.replicateOnStartup = true;

      remote.sanduny = {
        url = "depot@sanduny.tvl.su:/var/lib/depot";
        projects = "depot";
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

  services.depot.restic = {
    paths = [ "/var/lib/gerrit" ];
    exclude = [ "/var/lib/gerrit/tmp" ];
  };
}
