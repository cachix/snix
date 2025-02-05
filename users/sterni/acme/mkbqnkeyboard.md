# mkbqnkeyboard.bqn

[mkbqnkeyboard.bqn][] is a script that updates a given Plan 9 `/lib/keyboard`
file to support the familiar [BQN keymap][] via compose sequences. Since
it uses the GNU Readline [inputrc distributed with BQN][inputrc] as a database
for the keymap, you can use a [remapped][] version of the layout.
Once applied, you'll be able to type the Unicode characters used by BQN
via <kbd>Compose</kbd> followed by <kbd>\\</kbd> and the
<kbd>mapped ASCII character</kbd>. For details on the file and what button
is used for <kbd>Compose</kbd>, refer to
[keyboard(6)][p9f-keyboard] (see also
[plan9port's keyboard(7)][p9p-keyboard], [9front's keyboard(6)][9front-keyboard] etc.).

TIP: [mkbqnkeyboard.bqn][] has only been tested with [plan9port][],
so the instructions below may not work with every Plan 9 variant.
If you have any any information on/trouble with getting it to work on
a proper Plan 9 (fork), feel free to [let me know][me] or
[send a patch][submitting-patches].

The process for updating `/lib/keyboard` with [mkbqnkeyboard.bqn][] is a follows:

1. Prerequisites:

   - [CBQN][] (other BQN implementations are untested)
   - A local checkout of [mlochbaum/BQN][],
     `aecb56a323aa` is the latest tested revision.

2. Run

       ./mkbqnkeyboard.bqn -i /path/to/mlochbaum/BQN/editors/inputrc /path/to/lib/keyboard

   If you omit `-i`, the modified `keyboard` file will be printed to stdout instead
   of written to the file. If you add `-s`, the result will be sorted by (resulting) codepoint.

3. If you're using **plan9port**, you'll need to

   1. Apply [latin1-increase-compose-capacity.patch][] since the default compose
      sequence lookup table is too small to hold all the mappings BQN adds.
   2. Recompile plan9port.

   Other Plan 9 variants may also require extra steps.

4. The compose sequences should now work in the [acme][] and [sam][] text editors
   as well as all other Plan 9 programs.

[acme]: https://9p.io/sys/doc/acme/acme.pdf
[sam]: https://9p.io/sys/doc/sam/sam.pdf
[BQN keymap]: https://mlochbaum.github.io/BQN/keymap.html
[me]: https://grep.tvl.fyi/search/?q=%20path%3Aops%2Fusers%2Fdefault.nix%20name%20%3D%20%22sterni%22%3B&fold_case=auto&regex=false&context=true
[mkbqnkeyboard.bqn]: ./mkbqnkeyboard.bqn
[inputrc]: https://github.com/mlochbaum/BQN/blob/master/editors/inputrc
[remapped]: https://mlochbaum.github.io/BQN/editors/index.html#alternate-layouts
[p9f-keyboard]: https://p9f.org/magic/man2html/6/keyboard
[p9p-keyboard]: https://9fans.github.io/plan9port/man/man7/keyboard.html
[9front-keyboard]: http://man.9front.org/6/keyboard
[plan9port]: https://9fans.github.io/plan9port/
[submitting-patches]: https://code.tvl.fyi/about/docs/REVIEWS.md
[mlochbaum/BQN]: https://github.com/mlochbaum/BQN
[CBQN]: https://github.com/dzaima/cbqn
[latin1-increase-compose-capacity.patch]: ./plan9port/latin1-increase-compose-capacity.patch
