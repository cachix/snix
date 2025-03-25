#
# Forgejo Git Backend taken from Lix configuration.
# Thanks to all the Lix core developers for this!
# vim: et:ts=2:sw=2:
#
{ depot, pkgs, lib, config, ... }:
let
  cfg = config.services.depot.forgejo;
  inherit (lib) types mkEnableOption mkOption mkIf;
  emojo =
    let
      handlePostFetch = ''
        for i in $out/*_256.png; do
          mv $i $(echo $i | sed -E 's/_256//g')
        done
      '';
      drgn = pkgs.fetchzip {
        url = "https://volpeon.ink/emojis/drgn/drgn.zip";
        stripRoot = false;
        sha256 = "sha256-/2MpbxMJC92a4YhwG5rP6TsDC/q1Ng5fFq4xe2cBrrM=";
        postFetch = handlePostFetch;
      };
      neocat = pkgs.fetchzip {
        url = "https://volpeon.ink/emojis/neocat/neocat.zip";
        stripRoot = false;
        sha256 = "sha256-Irh6Mv6ICDkaaenIFf8Cm1AFkdZy0gRVbXqgnwpk3Qw=";
        postFetch = handlePostFetch;
      };
      neofox = pkgs.fetchzip {
        url = "https://volpeon.ink/emojis/neofox/neofox.zip";
        stripRoot = false;
        sha256 = "sha256-FSTVYP/Bt25JfLr/Ny1g9oI9aAvAYLYhct31j3XRXYc=";
        postFetch = handlePostFetch;
      };
      dragon = pkgs.fetchFromGitHub {
        owner = "chr-1x";
        repo = "dragn-emoji";
        rev = "969543d9918ce2f0794ccd1e41b276d1ab22f0d5";
        sha256 = "sha256-+40e9nKaIpQYZUiXh3Qe5jp2uvRbAQYDdXMGLEWHJio=";
        postFetch = ''
          for i in $out/*.svg; do
            ${pkgs.librsvg}/bin/rsvg-convert -h 256 $i > a.png;
            mv a.png $(echo $i | sed -E "s/svg$/png/");
            rm $i
          done
          ${pkgs.oxipng}/bin/oxipng -o max $out/*.png
        '';
      };
    in
    pkgs.symlinkJoin { name = "emojo"; paths = [ drgn neocat neofox dragon ]; };
in
{
  options.services.depot.forgejo = {
    enable = mkEnableOption "Forgejo Forge";

    domain = mkOption {
      type = types.str;
    };
  };

  config = mkIf cfg.enable {
    # we have to use redis since we apparently have a "large instance" which
    # "leaks hilarious amounts of memory if you use the default configuration"
    services.redis = {
      package = pkgs.valkey;

      vmOverCommit = true;
      servers.forgejo = {
        enable = true;
        # disable persistence, so when redis inevitably OOMs due to
        # forgejo throwing to much in it, we don't restore the dataset
        # that caused the OOM, breaking the restart loop.
        save = [ ];
      };
    };
    systemd.services.redis-forgejo.serviceConfig = {
      Restart = "always";
    };
    systemd.services.forgejo = {
      after = [ "redis-forgejo.service" ];
      wants = [ "redis-forgejo.service" ];
    };

    services.forgejo = {
      enable = true;

      package = pkgs.forgejo.overrideAttrs (old: {
        patches = old.patches ++ (with depot.third_party.lix_forgejo.patches; [
          upstream_link
          signin_redirect
          api_dont_notify
          forgejo_is_now_gerrit_native
          forgejo_knows_about_gerrit
        ]);
      });

      # General settings.
      lfs.enable = true;

      # Make our checkout paths more in line with expectations by calling our user "git".
      user = "git";
      group = "git";

      # Secret mail config.
      secrets.mailer.PASSWD = config.age.secrets.forgejo-smtp-passwd.path;

      # Server and database config.
      settings = {

        # Sets the name in the titlebar, mostly.
        DEFAULT.APP_NAME = "Snix Project";

        # Settings for how we serve things.
        server = {
          DOMAIN = cfg.domain;
          PROTOCOL = "http";
          ENABLE_ACME = true;
          ACME_ACCEPTTOS = true;
          ACME_EMAIL = "acme@snix.dev";
          LANDING_PAGE = "explore";
          ROOT_URL = "https://${cfg.domain}";

          # open a server on localhost:6060 with pprof data
          # !! note: the documentation says that this causes forgejo serv to dump
          # random files in PPROF_DATA_PATH.
          # This documentation is wrong, ENABLE_PPROF only affects forgejo web,
          # and forgejo serv requires a --enable-pprof arg to do that. But it's
          # not causing perf problems right now so we don't care about that
          # anyway.
          ENABLE_PPROF = true;
        };

        # openid is not used in our setup
        openid = {
          ENABLE_OPENID_SIGNIN = false;
          ENABLE_OPENID_SIGNUP = false;
        };

        oauth2_client = {
          ENABLE_AUTO_REGISTRATION = true;
          REGISTER_EMAIL_CONFIRM = false;
          ACCOUNT_LINKING = "login";
          USERNAME = "nickname";
          OPENID_CONNECT_SCOPES = "email profile";
        };

        repository = {
          DISABLE_DOWNLOAD_SOURCE_ARCHIVES = true;
        };

        cache = {
          ADAPTER = "redis";
          HOST = "redis+socket://${config.services.redis.servers.forgejo.unixSocket}";
        };
        "cache.last_commit" = {
          ITEM_TTL = "24h"; # from default 8760h (1 year)
        };

        service = {
          # We previously ran with "disable registration" which doesn't actually
          # do anything to the OAuth login form, just the link account form. We
          # suspect that if the account has all the required metadata like email
          # to register cleanly, it doesn't use DISABLE_REGISTRATION at all.
          #
          # However this was probably relying on forgejo bugs, let's set it
          # unambiguously.
          DISABLE_REGISTRATION = false;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          ENABLE_INTERNAL_SIGNIN = false;

          #REQUIRE_SIGNIN_VIEW = false;
          ENABLE_NOTIFY_MAIL = true;

          # Don't add org members as watchers on all repos, or indeed on new
          # repos either.
          #
          # See: https://github.com/bmackinney/gitea/commit/a9eb2167536cfa8f7b7a23f73e11c8edf5dc0dc0
          AUTO_WATCH_NEW_REPOS = false;
        };

        session = {
          # Put sessions in the DB so they survive restarts
          PROVIDER = "db";
          PROVIDER_CONFIG = "";

          # Cookie only works over https
          COOKIE_SECURE = true;

          # 5 day sessions
          SESSION_LIFE_TIME = 86400 * 5;
        };

        # Careful with these!
        security = {
          # Don't allow access to the install page; manage exclusively via Nix.
          INSTALL_LOCK = true;

          # Allow internal users with the right permissions to set up Git hooks.
          DISABLE_GIT_HOOKS = false;
        };

        # Note: PASSWD is set up by the NixOS module, which sets FORGEJO__MAILER__PASSWD__FILE.
        # https://forum.gitea.com/t/email-could-not-initiate-smtp-session-error/8164/14
        mailer = {
          ENABLED = true;
          PROTOCOL = "smtp+starttls";
          SMTP_ADDR = "smtp.postmarkapp.com";
          SMTP_PORT = 2525;
          USER = "PM-T-forgejo-48CsFdjTEW5_tALcpact0HG";
          FROM = "\"Snix Forgejo\" <forgejo@snix.dev>";
        };

        ui = {
          # Add the used emojis from https://volpeon.ink/emojis/ as well as https://github.com/chr-1x/dragn-emoji
          CUSTOM_EMOJIS = builtins.readFile depot.third_party.lix_forgejo.custom_emojis;
          # Normal reaction emoji people always need.
          REACTIONS = "+1, -1, laugh, confused, heart, hooray, eyes, melting_face, neocat_scream_scared, neofox_scream_scared, drgn_scream, neocat_heart, neofox_heart, drgn_heart, neocat_floof_reach, neocat_pleading, neofox_floof_reach, neofox_pleading, drgn_pleading";

          # To protect privacy of users.
          SHOW_USER_EMAIL = false;
        };

        # No runners are configured.
        actions.ENABLED = false;
      };

      # Use a MySQL database, which we enable below.
      database = {
        type = "mysql";
        user = config.services.forgejo.user;
      };
    };

    # Inspired from Gerrit's way of doing things (from Lix).
    # Before starting Forgejo, we will re-converge any required information.
    # TODO: learn how to use update-oauth as well?
    systemd.services.forgejo-keys = {
      enable = true;

      before = [ "forgejo.service" ];
      wantedBy = [ "forgejo.service" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "true";
        WorkingDirectory = "/var/lib/forgejo";
        User = "git";
        Group = "git";
        Environment = [
          "FORGEJO_WORK_DIR=/var/lib/forgejo"
        ];
      };

      path = [ config.services.forgejo.package ];

      script = ''
        NAME="Snix project"
        PROVIDER="openidConnect"
        CLIENT_ID="forgejo"
        CLIENT_SECRET=$(cat ${config.age.secrets.forgejo-oauth-secret.path})
        DISCOVERY_URL="https://auth.snix.dev/realms/snix-project/.well-known/openid-configuration"
        SCOPES=("openid" "profile" "email")

        # Check if the OAuth2 source already exists
        if gitea admin auth list | grep -q "$NAME"; then
          echo "OAuth2 source '$NAME' already exists. Skipping creation."
          exit 0
        fi

        # Add the OAuth2 source
        gitea admin auth add-oauth \
          --name "$NAME" \
          --provider "$PROVIDER" \
          --key "$CLIENT_ID" \
          --secret "$CLIENT_SECRET" \
          --auto-discover-url "$DISCOVERY_URL" \
          $(printf -- '--scopes "%s" ' "''${SCOPES[@]}") \
          --icon-url "$ICON_URL"

        echo "OAuth2 source '$NAME' added successfully."
      '';
    };

    # Create our user an group. This is necessary for any name that's
    # not "forgejo", due to the nix module config.
    users.users."${config.services.forgejo.group}" = {
      description = "Gitea Service";
      useDefaultShell = true;

      home = config.services.forgejo.stateDir;
      group = config.services.forgejo.group;

      # redis instance runs as redis-forgejo, so we need to be in that group to be able to connect
      extraGroups = [ "redis-forgejo" ];

      isSystemUser = true;
    };
    users.groups."${config.services.forgejo.group}" = { };

    # Enable the mysql server, which will provide the forgejo backing store.
    services.mysql.enable = lib.mkForce true;
    services.mysql.package = lib.mkForce pkgs.mariadb;

    systemd.tmpfiles.rules = let cfg = config.services.forgejo; in [
      "d '${cfg.customDir}/public/assets' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.customDir}/public/assets/img' 0750 ${cfg.user} ${cfg.group} - -"
      "L+ '${cfg.customDir}/public/assets/img/emoji' - - - - ${emojo}"
    ];
  };
}
