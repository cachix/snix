#!/usr/bin/env BQN
# SPDX-FileCopyrightText: Copyright © 2024 sterni
# SPDX-License-Identifier: GPL-3.0-only
#
# blërg is a reimplementation of mblog in BQN. BQN is used as a sort of bespoke
# scripting languages so we can rely on external tools for certain tasks (e.g.
# transforming HTML and parsing MIME messages).
#
# Specifically, blërg depends on:
# - mblaze
# - mn2html
# - execline (to work around the lack of cwd in BQN)

# Utilities

MkDirP ← •file.CreateDir⍟(¬•file.Exists)

AsciiDown ← ('A'-'a')⊸(⊢-×⟜('A'⊸≤∧≤⟜'Z'))

nl ← @+10

SplitChar ← ((=(¯1˙⍟⊣)¨+`∘=)⊔⊢)
Lines ← nl⊸SplitChar

ReadPosInt ← {(𝕨⊸×+⊣)´∘⌽-⟜'0'𝕩} # ty leah2
ReadPosDec ← 10⊸ReadPosInt

ApplyMany ← {fs 𝕊 arg: {𝕏 arg}¨ fs}

Chomp ← {⟨nl⟩≡¯1↑𝕩? ¯1↓𝕩; 𝕩}

Run ← {
  𝕊 𝕩: 1 𝕊 𝕩;
  doChomp 𝕊 cmd:
  exit‿stdout‿stderr ← •SH cmd
  •term.ErrRaw⍟(0≠exit) stderr
  ⟨Chomp⍟doChomp stdout, exit⟩
}

R ← {𝕊 stdout‿exit: !0=exit ⋄ stdout}∘Run
LR ← Lines∘R

# (Apple) Mail Notes Backend

# TODO(sterni): avoid argv limit by chunking
Hdr ← {LR "mhdr"‿"-dh"‿𝕨∾𝕩}
Date ← {ReadPosDec¨ LR "mhdr"‿"-Dh"‿"Date"∾𝕩}

MailNotesBackend ← {𝕊 mailDir:
  Filter ← {𝕩 ("com.apple.mail-note"⊸≡¨/⊣) "X-Uniform-Type-Identifier" Hdr 𝕩}
  Id ← AsciiDown "X-Universally-Unique-Identifier"⊸Hdr
  Title ← "Subject"⊸Hdr
  MkRenderer ← {𝕊 p: {R "execline-cd"‿𝕩‿"mshow"‿"-x"‿p ⋄ R "mn2html"‿p}}
  # TODO(sterni): entries could become namespaces
  Entries ⇐ {𝕊: ⍉>⟨Id,Title,Date,MkRenderer¨⟩⊸ApplyMany Filter LR "mlist"‿mailDir}
}

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

WriteEntry ← {outDir 𝕊 id‿title‿·‿renderEntry:
  entryDir ← MkDirP outDir •file.At id
  (entryDir •file.At "index.html") •file.Chars title RenderPage RenderEntry entryDir
  # TODO(sterni): urlencode
  "<li><a href="""∾id∾""">"∾title∾"</a></li>"
}

# Main

mailDir‿outDir ← {
  # Usage: blërg <maildir> <out dir>
  ! 2=≠•args
  # TODO(sterni): expand ~/
  •wdpath⊸•file.At¨ •args
}

m ← MailNotesBackend mailDir
entries ← ((⍒ 2⊸⊑˘)⊏⊢) m.Entries @

title ← "blërg"

MkDirP outDir
entryIndex ← (< outDir⊸WriteEntry)˘ entries
(outDir •file.At "index.html") •file.Chars title RenderPage ∾"<ul>"∾entryIndex∾"</ul>"
