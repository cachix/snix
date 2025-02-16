#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Copyright (c) 2024 by sterni
#
# WARNING: This script is not well tested and may find a way to eat your commits.
#
# git only-push lets you push a specific range or list of commits to a remote
# ref based on a given revision (defaults to refs/remotes/origin/HEAD). This can
# be useful to push a subset of commits (that are ready for review) from a local
# commit chain to a PR branch (or gerrit style review ref).
#
# This is achieved by cherry-picking the relevant commits onto the base revision
# in a temporary worktree. For this the commits need to apply independently of
# prior commits not included in the selection, of course.
#
# git only-push is to be considered experimental. Its command line interface is
# janky and may be revised.

set -eu

die() {
  printf '%s: %s\n' "$(basename "$0")" "$2"
  exit "$1"
}

usage() {
  printf '%s\n' \
    "git only-push [-n] [-f] [-x] [-b <rev>] -r <remote> -t <refspec> [--] <commit>..." \
    >&2
}

base=refs/remotes/origin/HEAD
dry=false

# TODO(sterni): non-interactive mode, e.g. clean up also on cherry-pick failure
while getopts "b:r:t:nxfh" opt; do
  case $opt in
    # TODO(sterni): it is probably too close to --branch?
    b)
      base="$OPTARG"
      ;;
    t)
      to="$OPTARG"
      ;;
    r)
      remote="$OPTARG"
      ;;
    n)
      dry=true
      ;;
    x)
      cherry_pick_x=true
      ;;
    f)
      # TODO(sterni): support --force-with-lease
      push_f=true
      ;;
    h|?)
      usage
      # TODO(sterni): add man page
      # shellcheck disable=SC2016
      [ "$opt" = "h" ] && printf '
\t-r <remote>\tRemote to push to.
\t-t <refspec>\tTarget ref to push to.
\t-b <rev>\tOptional: Base revision to cherry-pick commits onto. Defaults to refs/remotes/origin/HEAD.
\t-x\t\tUse `git cherry-pick -x` for creating cherry-picks.
\t-f\-\tForce push to remote ref.
\t-n\t\tDry run.
'
      [ "$opt" = "h" ] && exit 0 || exit 100
      ;;
  esac
done

shift $((OPTIND - 1))

if [ -z "${to:-}" ]; then
  usage
  die 100 "Missing -t flag"
fi

if [ -z "${remote:-}" ]; then
  usage
  die 100 "Missing -r flag"
fi

if [ "$#" -eq 0 ]; then
  usage
  die 100 "Missing commits"
fi

repo="$(git rev-parse --show-toplevel)"
worktree=

cleanup() {
  test -n "$worktree" && test -e "$worktree" \
    && git -C "$repo" worktree remove "$worktree"
}
trap cleanup EXIT

if $dry; then
  printf 'Would create worktree and checkout %s\n' "$base" >&2
else
  worktree="$(mktemp -d)"
  git -C "$repo" worktree add "$worktree" "$base"
fi

for arg in "$@"; do
  # Resolve ranges, get them into chronological order
  revs="$(git -C "$repo" rev-list --no-walk "$arg" | tac)"

  for rev in $revs; do
    if $dry; then
      printf 'Would cherry pick %s\n' "$rev" >&2
    else
      no_cherry_pick=false
      git -C "$worktree" cherry-pick ${cherry_pick_x:+-x} "$rev" || no_cherry_pick=true
      if $no_cherry_pick; then
        tmp="$worktree"
        # Prevent cleanup from removing the worktree
        worktree=""
        die 101 "Could not cherry pick $rev. Please manually fixup worktree at $tmp"
      fi
    fi
  done
done

if $dry; then
  printf 'Would push resulting HEAD to %s on %s\n' "$to" "$remote" >&2
else
  git -C "$worktree" push ${push_f:+-f} "$remote" "HEAD:$to"
fi
