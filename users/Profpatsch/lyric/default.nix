{ pkgs, depot, lib, ... }:

let
  bins = depot.nix.getBins pkgs.sqlite [ "sqlite3" ]
    // depot.nix.getBins pkgs.util-linux [ "unshare" ]
    // depot.nix.getBins pkgs.coreutils [ "echo" ]
    // depot.nix.getBins pkgs.gnused [ "sed" ]
    // depot.nix.getBins pkgs.squashfuse [ "squashfuse" ]
    // depot.nix.getBins pkgs.jq [ "jq" ];

  mpv-script = pkgs.writeTextFile {
    name = "lyric.lua";
    text =
      lib.replaceStrings
        [ "@get_subtitles_command@" ]
        [ (toString lyric-to-temp-file) ]
        (builtins.readFile ./lyric-mpv-script.lua);
    derivationArgs.passthru.scriptName = "lyric.lua";
  };

  lyric-to-temp-file = depot.nix.writeExecline "lyric-to-temp-file" { readNArgs = 1; } [
    "backtick"
    "-E"
    "cache"
    [ depot.users.Profpatsch.xdg-cache-home ]
    "if"
    [ "mkdir" "-p" "\${cache}/lyric/as-files" ]
    "if"
    [
      "redirfd"
      "-w"
      "1"
      "\${cache}/lyric/as-files/\${1}.lrc"
      lyric
      "$1"
    ]
    "printf"
    "\${cache}/lyric/as-files/\${1}.lrc"
  ];

  # looool
  escapeSqliteString = depot.nix.writeExecline "escape-sqlite-string" { readNArgs = 1; } [
    "pipeline"
    [
      "printf"
      "%s"
      "$1"
    ]
    bins.sed
    "s/''/''''/g"
  ];

  # Display lyrics for the given search string;
  # search string can contain a substring of band name, album name, song title
  #
  # Use the database dump from https://lrclib.net/db-dumps and place it in ~/.cache/lyric/lrclib-db-dump.sqlite3
  #
  # TODO: put in the nodejs argh
  lyric =
    (depot.nix.writeExecline "lyric" { readNArgs = 1; } [
      "backtick"
      "-E"
      "cache"
      [ depot.users.Profpatsch.xdg-cache-home ]
      # make sure the squashfuse is only mounted while the command is running
      bins.unshare
      "--user"
      "--mount"
      "--pid"
      "--map-root-user"
      "--kill-child"
      "if"
      [ "mkdir" "-p" "\${cache}/lyric/dump" ]
      # TODO: provide a command that takes an url of a lyric.gz and converts it to this here squash image
      "if"
      [ bins.squashfuse "-ononempty" "\${cache}/lyric/lyric-db.squash" "\${cache}/lyric/dump" ]
      # please help me god
      "backtick"
      "-E"
      "searchstring"
      [ escapeSqliteString "$1" ]
      "pipeline"
      [
        "pipeline"
        [
          "echo"
          (''
            .mode json
            select * from (
              -- first we try to find if we can find the track verbatim
              select * from (select
                  synced_lyrics,
                  has_synced_lyrics,
                  plain_lyrics
              from
                  tracks_fts('' + "'\${searchstring}'" + '') tf
                join tracks t on t.rowid = tf.rowid
                join lyrics l on t.rowid = l.track_id
            order by
                has_synced_lyrics desc, t.id
            )
            UNION
            select * from (select
                synced_lyrics,
                has_synced_lyrics,
                plain_lyrics
            from
                tracks_fts('' + "'\${searchstring}'" + '') tf
                join tracks t on t.rowid = tf.rowid
                join lyrics l on t.rowid = l.track_id
            order by
                has_synced_lyrics desc, t.id
            )
          )
          where synced_lyrics is not null and synced_lyrics != ''''
          and plain_lyrics is not null and plain_lyrics != ''''
          limit
              1;
        ''
          )
        ]
        bins.sqlite3
        "file:\${cache}/lyric/dump/lrclib-db-dump.sqlite3?immutable=1"
      ]
      bins.jq
      "-r"
      ''
        if .[0] == null
        then ""
        else
        .[0]
            | if .has_synced_lyrics == 1
            then .synced_lyrics
            else .plain_lyrics
            end
        end
      ''
    ]);


  js = depot.users.Profpatsch.napalm.buildPackage ./. { };

in
{
  inherit
    lyric
    js
    mpv-script;
}
