#!/usr/bin/env BQN
# SPDX-FileCopyrightText: Copyright © 2024-2025 sterni
# SPDX-License-Identifier: GPL-3.0-only
#
# blërg is a reimplementation of mblog in BQN. BQN is used as a sort of bespoke
# scripting languages so we can rely on external tools for certain tasks (e.g.
# transforming HTML and parsing MIME messages). A list of dependencies is
# maintained in README.md.

# Utilities

MkDirP ← •file.CreateDir⍟(¬•file.Exists)

AsciiDown ← ('A'-'a')⊸(⊢-×⟜('A'⊸≤∧≤⟜'Z'))
Slugify ← '-'⊸⊣⍟(¬(('A'⊸≤∧'z'⊸≥)∨<⊸(⊑∊)⟜"-_0123456789"))¨ AsciiDown

DropPrefix ← {𝕩(≠/⊣)𝕨↑˜≠𝕩}
StripLeft ← ((¬ ∧`∘=)/⊢)
StripRight ← ⌽ StripLeft⟜⌽

_join ← {(∾⟜(𝕗⊸∾))´𝕩;𝕨∾𝕗∾𝕩}

nl ← @+10
SplitChar ← ((=(¯1˙⍟⊣)¨+`∘=)⊔⊢)
Lines ← nl⊸SplitChar

ReadPosInt ← {(𝕨⊸×+⊣)´∘⌽-⟜'0'𝕩} # ty leah2
ReadPosDec ← 10⊸ReadPosInt

Chomp ← {⟨nl⟩≡¯1↑𝕩? ¯1↓𝕩; 𝕩}

Run ← {
  𝕊 𝕩: 1 𝕊 𝕩;
  doChomp 𝕊 cmd:
  exit‿stdout‿stderr ← •SH cmd
  exit∾Chomp⍟doChomp¨ stdout‿stderr
}

R ← {𝕊 exit‿stdout‿stderr: stderr!0=exit ⋄ stdout}∘Run
LR ← Lines∘R

GetEnv ← {R "importas"‿"env"‿𝕩‿"printf"‿"%s"‿"$env"}

RelPath ← •wdpath⊸•file.At
Ext ← '.'⊸(⊑∘1⊸↑∘/∘(=∧∊∘⊢)↑⊢)⌾⌽ •file.Name

# 3p dependencies

j ← {
  # Update README.md if dependency discovery changes
  ⟨Parse⟩ ⇐ •Import (GetEnv "BQN_LIBS") •file.At "json.bqn"

  ObjGet ⇐ (⊏⊸(⊑∘⊐) ⊑ ⊏˜⟜1)⟜<
  ObjGetPath ⇐ ObjGet˜´⟜⌽

  _objGetDef ⇐ {𝕨 (⊏⊸(⊑∘⊐) ⊑ (∾⟜(⋈𝕗))∘(⊏˜⟜1)) <𝕩}
}

# (Apple) Mail Notes Backend

# TODO(sterni): avoid argv limit by chunking
Hdrs ← {LR "mhdr"‿"-dh"‿(':' _join 𝕨)∾𝕩}
Dates ← {ReadPosDec¨ LR "mhdr"‿"-Dh"‿"Date"∾𝕩}
headerNames ← "X-Uniform-Type-Identifier"‿"X-Universally-Unique-Identifier"‿"Subject"

MailNotesBackend ← {𝕊 config:
  mailDir ← RelPath config j.ObjGet "maildir"
  Entries ⇐ {𝕊:
    ms ← LR "mlist"‿mailDir
    th ← ⟨≠ms,≠headerNames⟩⥊headerNames Hdrs ms
    dh ← Dates ms
    ah ← (("com.apple.mail-note"⊸≡⊑)˘/⊢) th∾˘dh≍˘ms
    {𝕊 ·‿uuid‿title‿time‿path:
      title ⇐ ⋄ time ⇐
      id ⇐ Slugify uuid
      Render ⇐ {R "execline-cd"‿𝕩‿"mshow"‿"-x"‿path ⋄ R "mn2html"‿path}
    }˘ ah
  }
}

# Git Backend

converters ← ⍉>⟨
# TODO(sterni): avoid cat
⟨"html", ⋈"cat"⟩,
⟨"md", "lowdown"‿"-T"‿"html"‿"--html-no-skiphtml"‿"--html-no-escapehtml"‿"--html-callout-mdn"⟩,
# TODO(sterni): use emacs
⟨"org", "pandoc"‿"-f"‿"org"‿"-t"‿"html5"⟩,
⟩

# TODO(sterni): don't assemble blocks in this ad hoc fashion
# TODO(sterni): pipefail
PipelineCmd ← {"pipeline"⋈⊸∾(' '⊸∾¨𝕨)∾""⋈⊸∾𝕩}

GitBackend ← {𝕊 config:
  repo ← RelPath •file.At config j.ObjGet "repository"
  path ← ∾⟜'/' '/' StripRight config "." j._ObjGetDef "path"

  # We use zero separated fields when dealing with paths, so quoting is unnecessary
  GitCmd ← {"git"‿"-c"‿"core.quotePath=false"‿"-C"‿repo∾𝕩}
  rev ← R GitCmd "rev-parse"‿"HEAD"
  # Use the author date of the latest commit on the file to establish the date
  # of the file. The author date is easier to arbitrarily change and survives
  # history rewrites. It could be interesting to ignore commits that touch
  # multiple files (especially treewide ones).
  PathDate ← {ReadPosDec R GitCmd "log"‿"--date=unix"‿"--pretty=tformat:%ad"‿"-1"‿rev‿"--"‿𝕩}

  Entries ⇐ {𝕤⋄
    blobs ← ∘‿2⥊@ SplitChar R GitCmd "ls-tree"‿"-zr"‿"--format=%(path)%x00%(objectname)"‿rev‿path
    {𝕊 p‿b:
      id ⇐ Slugify path DropPrefix p
      # TODO(sterni): extract from file if possible
      title ⇐ •file.Name p
      time ⇐ PathDate p
      Render ⇐ {𝕤
        conv ← converters j.ObjGet Ext p
        R (GitCmd "cat-file"‿"blob"‿b) PipelineCmd conv
      }
    }˘blobs
  }
}

backends ← ⍉>⟨"mail-notes"‿mailNotesBackend, "git"‿gitBackend⟩

# Rendering

RenderPage ← {
∾"<!doctype html>
<html lang=""en"">
<head>
<meta charset=""utf-8"">
<title>"‿𝕨‿"</title>
<body>
<h1>"‿𝕨‿"</h1>"‿𝕩
}

WriteEntry ← {outDir 𝕊 entry:
  entryDir ← MkDirP outDir •file.At entry.id
  (entryDir •file.At "index.html") •file.Chars entry.title RenderPage entry.Render entryDir
  # TODO(sterni): urlencode
  "<li><a href="""∾entry.id∾""">"∾entry.title∾"</a></li>"
}

# Main

configFile‿outDir ← {
  # Usage: blërg <config file> <out dir>
  ! 2=≠•args
  # TODO(sterni): expand ~/
  RelPath¨ •args
}

config ← {
  raw ← j.Parse •FChars configFile

  [bns,bcs] ← raw j.ObjGet "backends"
  bcs ↩ bcs ∾˘⟜{2‿1⊸⥊"name"‿𝕩}¨ bns
  bts ← (j.ObjGet⟜"type")˜¨ bcs
  backends ⇐ bcs {𝕏 𝕨}¨ backends⊸j.ObjGet¨ bts

  title ⇐ raw j.ObjGet "title"
}

entries ← (<"time") ((⍒∘(•ns.Get˜¨))⊏⊢) ∾{𝕩.Entries @}¨ config.backends
# TODO(sterni): assert id uniqueness

MkDirP outDir
entryIndex ← outDir⊸WriteEntry¨ entries
(outDir •file.At "index.html") •file.Chars config.title RenderPage ∾"<ul>"∾entryIndex∾"</ul>"
