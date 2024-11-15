{ depot, pkgs, lib, config, ... }:

let
  virtualHost = "code.sterni.lv";

  repoSections = [
    {
      section = "active";
      repos = {
        spacecookie = {
          description = "gopher server (and library for Haskell)";
          upstream = "https://github.com/sternenseemann/spacecookie.git";
        };
        "mirror/depot" = {
          description = "monorepo for the virus lounge";
          upstream = "https://code.tvl.fyi/depot.git";
          cgit.defbranch = "canon";
        };
        "mirror/flipdot-gschichtler" = {
          description = "message queue system for OpenLab's flipdot display";
          upstream = "https://github.com/openlab-aux/flipdot-gschichtler.git";
        };
        "mirror/nixpkgs" = {
          description = "Nix packages collection";
          upstream = "https://github.com/nixos/nixpkgs.git";
          cgit.enable-commit-graph = "0"; # too slow
        };
        "mirror/vuizvui" = {
          description = "Nix(OS) expressions used by the OpenLab and its members";
          upstream = "https://github.com/openlab-aux/vuizvui.git";
        };
      };
    }
    {
      section = "poc";
      repos = {
        emoji-generic = {
          description = "generic emoji library for Haskell";
          upstream = "https://github.com/sternenseemann/emoji-generic.git";
        };
        grav2ty = {
          description = "“realistic” 2d space game";
          upstream = "https://github.com/sternenseemann/grav2ty.git";
        };
        haskell-dot-time = {
          description = "UTC-centric time library for haskell with dot time support";
          cgit.defbranch = "main";
        };
        buchstabensuppe = {
          description = "toy font rendering for low pixelcount, high contrast displays";
          upstream = "https://github.com/sternenseemann/buchstabensuppe.git";
          cgit.defbranch = "main";
        };
        "mirror/saneterm" = {
          description = "modern line-oriented terminal emulator without support for TUIs";
          upstream = "https://git.8pit.net/saneterm.git";
        };
      };
    }
    {
      # TODO(sterni): resisort, klammeraffe, cl-ca, ponify, tinyrl
      section = "archive";
      repos = {
        gopher-proxy = {
          description = "Gopher over HTTP proxy";
          upstream = "https://github.com/sternenseemann/gopher-proxy.git";
        };
        likely-music = {
          description = "experimental application for probabilistic music composition";
          upstream = "https://github.com/sternenseemann/likely-music.git";
        };
        logbook = {
          description = "file format for keeping a personal log";
          upstream = "https://github.com/sternenseemann/logbook.git";
        };
        sternenblog = {
          description = "file based cgi blog software";
          upstream = "https://github.com/sternenseemann/sternenblog.git";
        };
      };
    }
  ];

  repoPath = name: repo: repo.path or "/srv/git/${name}.git";

  cgitRepoEntry = name: repo:
    lib.concatStringsSep "\n" (
      [
        "repo.url=${name}"
        "repo.path=${repoPath name repo}"
      ]
      ++ lib.optional (repo ? description) "repo.desc=${repo.description}"
      ++ lib.mapAttrsToList (n: v: "repo.${n}=${v}") repo.cgit or { }
    );

  cgitHead = pkgs.writeText "cgit-head.html" ''
    <style>
    #summary {
      max-width: 80em;
    }

    #summary * {
      max-width: 100%;
    }
    </style>
  '';

  cgitConfig = pkgs.writeText "cgitrc" ''
    virtual-root=/

    enable-http-clone=1
    clone-url=https://${virtualHost}/$CGIT_REPO_URL

    enable-blame=1
    enable-log-filecount=1
    enable-log-linecount=1
    enable-index-owner=0
    enable-blame=1
    enable-commit-graph=1

    root-title=code.sterni.lv
    root-desc=
    css=/cgit.css
    head-include=${cgitHead}

    mimetype-file=${pkgs.mime-types}/etc/mime.types

    noplainemail=1

    about-filter=${depot.tools.cheddar.about-filter}/bin/cheddar-about
    source-filter=${depot.tools.cheddar}/bin/cheddar
    readme=:README.md
    readme=:readme.md

    section-sort=0
    ${
      lib.concatMapStringsSep "\n" (section:
        ''
          section=${section.section}

        ''
        + builtins.concatStringsSep "\n\n" (lib.mapAttrsToList cgitRepoEntry section.repos)
      ) repoSections
    }
  '';

  /* Merge a list of attrs, but fail when the same attribute occurs twice.

     Type: [ attrs ] -> attrs
  */
  mergeManyDistinctAttrs = lib.foldAttrs
    (
      val: nul:
        if nul == null then val else throw "Every attribute name may occur only once"
    )
    null;

  flatRepos = mergeManyDistinctAttrs
    (builtins.map (section: section.repos) repoSections);

  reposToMirror = lib.filterAttrs (_: repo: repo ? upstream) flatRepos;

  # User and group name used for running the mirror scripts
  mirroredReposOwner = "git";

  # Make repo name suitable for systemd unit/timer
  unitName = name: "mirror-${lib.strings.sanitizeDerivationName name}";
in

{
  imports = [
    ./nginx.nix
  ];

  config = {
    services.fcgiwrap.instances.cgit = {
      process = {
        user = "http";
        group = "http";
      };
      socket = {
        user = "http";
        group = "http";
      };
    };

    services.nginx.virtualHosts."${virtualHost}" = {
      enableACME = true;
      forceSSL = true;
      root = "${pkgs.cgit-pink}/cgit/";
      extraConfig = ''
        try_files $uri @cgit;

        location @cgit {
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param    SCRIPT_FILENAME ${pkgs.cgit-pink}/cgit/cgit.cgi;
          fastcgi_param    PATH_INFO       $uri;
          fastcgi_param    QUERY_STRING    $args;
          fastcgi_param    HTTP_HOST       $server_name;
          fastcgi_param    CGIT_CONFIG     ${cgitConfig};
          fastcgi_pass     unix:${toString config.services.fcgiwrap.instances.cgit.socket.address};
        }
      '';
    };

    users = {
      users.${mirroredReposOwner} = {
        group = mirroredReposOwner;
        isSystemUser = true;
      };

      groups.${mirroredReposOwner} = { };
    };


    systemd.timers = lib.mapAttrs'
      (
        name: repo:
          {
            name = unitName name;
            value = {
              description = "regularly update mirror git repository ${name}";
              wantedBy = [ "timers.target" ];
              enable = true;
              timerConfig = {
                # Fire every 6h and distribute the workload over next 6h randomly
                OnCalendar = "*-*-* 00/6:00:00";
                RandomizedDelaySec = "6h";
                Persistent = true;
              };
            };
          }
      )
      reposToMirror;

    systemd.services = lib.mapAttrs'
      (
        name: repo:
          {
            name = unitName name;
            value = {
              description = "mirror git repository ${name}";
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];

              script =
                let
                  path = repoPath name repo;
                in
                ''
                  set -euo pipefail

                  export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.git ]}"

                  if test ! -d "${path}"; then
                    mkdir -p "$(dirname "${path}")"
                    git clone --mirror "${repo.upstream}" "${path}"
                    exit 0
                  fi

                  cd "${path}"

                  git fetch "${repo.upstream}" '+refs/*:refs/*' --prune

                  # no auto gc here and we're not pruning for nothing…
                  git gc
                '';

              serviceConfig = {
                Type = "oneshot";
                User = mirroredReposOwner;
                Group = mirroredReposOwner;
              };
            };
          }
      )
      reposToMirror;
  };
}
