# blërg

## dependencies

- [CBQN][] (other [BQN][] implementations may work, but are untested)
- Marshall Lochbaum's [bqn-libs][] which blërg expects to find at the
  location the `BQN_LIBS` environment variable points to.
- [execline][]
- POSIX `printf(1)` (e.g. from GNU coreutils)
- `mail-notes` backend
  - //users/sterni/mn2html
  - [mblaze(7)][mblaze]
- `git` backend
  - [git][]
  - [lowdown][] for Markdown support
  - [pandoc][] for Org Mode support

[mblaze]: https://github.com/leahneukirchen/mblaze/
[execline]: https://skarnet.org/software/execline/
[BQN]: https://mlochbaum.github.io/BQN/
[CBQN]: https://github.com/dzaima/cbqn
[bqn-libs]: https://github.com/mlochbaum/bqn-libs/
[lowdown]: https://kristaps.bsd.lv/lowdown/
[pandoc]: https://pandoc.org/
[git]: https://git-scm.com/
