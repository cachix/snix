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
  •term.ErrRaw⍟(0≠exit) stderr
  ⟨Chomp⍟doChomp stdout, exit⟩
}

R ← {𝕊 stdout‿exit: !0=exit ⋄ stdout}∘Run
LR ← Lines∘R

# (Apple) Mail Notes Backend

# TODO(sterni): avoid argv limit by chunking
Hdrs ← {LR "mhdr"‿"-dh"‿(':' _join 𝕨)∾𝕩}
Dates ← {ReadPosDec¨ LR "mhdr"‿"-Dh"‿"Date"∾𝕩}
headerNames ← "X-Uniform-Type-Identifier"‿"X-Universally-Unique-Identifier"‿"Subject"

MailNotesBackend ← {𝕊 mailDir:
  Entries ⇐ {𝕊:
    ms ← LR "mlist"‿mailDir
    th ← ⟨≠ms,≠headerNames⟩⥊headerNames Hdrs ms
    dh ← Dates ms
    ah ← (("com.apple.mail-note"⊸≡⊑)˘/⊢) th∾˘dh≍˘ms
    {𝕊 ·‿uuid‿title‿time‿path:
      title ⇐ ⋄ time ⇐
      id ⇐ AsciiDown uuid
      Render ⇐ {"execline-cd"‿𝕩‿"mshow"‿"-x"‿path ⋄ R "mn2html"‿path}
    }˘ ah
  }
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

WriteEntry ← {outDir 𝕊 entry:
  entryDir ← MkDirP outDir •file.At entry.id
  (entryDir •file.At "index.html") •file.Chars entry.title RenderPage entry.Render entryDir
  # TODO(sterni): urlencode
  "<li><a href="""∾entry.id∾""">"∾entry.title∾"</a></li>"
}

# Main

mailDir‿outDir ← {
  # Usage: blërg <maildir> <out dir>
  ! 2=≠•args
  # TODO(sterni): expand ~/
  •wdpath⊸•file.At¨ •args
}

m ← MailNotesBackend mailDir
entries ← (<"time") ((⍒∘(•ns.Get˜¨))⊏⊢) m.Entries @

title ← "blërg"

MkDirP outDir
entryIndex ← outDir⊸WriteEntry¨ entries
(outDir •file.At "index.html") •file.Chars title RenderPage ∾"<ul>"∾entryIndex∾"</ul>"
