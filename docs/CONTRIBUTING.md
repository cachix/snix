Contribution Guidelines
=======================

<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Contribution Guidelines](#contribution-guidelines)
    - [Before making a change](#before-making-a-change)
    - [Commit messages](#commit-messages)
    - [Commit content](#commit-content)
    - [Code quality](#code-quality)
    - [Builds & tests](#builds--tests)
    - [Submitting changes](#submitting-changes)

<!-- markdown-toc end -->

This is a loose set of "guidelines" for contributing to the depot. Please note
that we will not accept any patches that don't follow these guidelines.

Also consider the [code of conduct](./CODE_OF_CONDUCT.md). No really,
you should.

## Before making a change

Before making a change, consider your motivation for making the change.
Documentation updates, bug fixes and the like are *always* welcome.

When adding a feature you should consider whether it is only useful for your
particular use-case or whether it is generally applicable for other users of the
project.

When in doubt - just ask! You can reach out to us via mail at
[depot@tvl.su](mailto:depot@tvl.su) or on IRC.

## Commit messages

All commit messages should be structured like this:

```
type(scope): Subject line with at most a 72 character length

Body of the commit message with an empty line between subject and
body. This text should explain what the change does and why it has
been made, *especially* if it introduces a new feature.

Relevant issues should be mentioned if they exist.
```

Where `type` can be one of:

* `feat`: A new feature has been introduced
* `fix`: An issue of some kind has been fixed
* `docs`: Documentation or comments have been updated
* `style`: Formatting changes only
* `refactor`: Hopefully self-explanatory!
* `test`: Added missing tests / fixed tests
* `chore`: Maintenance work
* `subtree`: Subtree merges or updates, see also [Importing projects into depot][]

And `scope` should refer to some kind of logical grouping inside of the project.

It does not make sense to include the full path unless it aids in
disambiguating. For example, when changing the configuration of the host
`whitby` at `//ops/machines/whitby` it is enough to write `feat(whitby): ...`.

Please take a look at the existing commit log for examples.

This way of writing commit messages is known as [Conventional Commits][] and
should bring these advantages:

* automatic creation of changelogs from commit messages
* disciplined commit hygiene: one focused change per commit
* filtering of commit history by type

## Commit content

Multiple changes should be divided into multiple git commits whenever possible.
Common sense applies.

The fix for a single-line whitespace issue is fine to include in a different
commit. Introducing a new feature and refactoring (unrelated) code in the same
commit is not fine.

`git commit -a` is generally **taboo**.

In my experience making "sane" commits becomes *significantly* easier as
developer tooling is improved. The interface to `git` that I recommend is
[magit][]. Even if you are not yet an Emacs user, it makes sense to install
Emacs just to be able to use magit - it is really that good.

For staging sane chunks on the command line with only git, consider `git add
-p`.

## Code quality

This one should go without saying - but please ensure that your code quality
does not fall below the rest of the project. This is of course very subjective,
but as an example if you place code that throws away errors into a block in
which errors are handled properly your change will be rejected.

In my experience there is a strong correlation between the visual appearance of
a code block and its quality. This is a simple way to sanity-check your work
while squinting and keeping some distance from your screen ;-)

## Builds & tests

All projects are built using [Nix][] to avoid "build pollution" via the user's
environment.

If you have Nix installed and are contributing to a project tracked in this
repository, you can usually build the project by calling `nix-build -A
path.to.project`.

For example, to build a project located at `//tools/foo` you would call
`nix-build -A tools.foo` from the repository root. `//tools/magrathea`
(which is added to `PATH` automatically if you enable [direnv][])
allows you to do the same via `mg build //tools/foo`
regardless of what your working directory is.

If the project has tests, check that they still work before submitting your
change.

## Submitting changes

The code review & change submission process is described in the [code
review][] documentation.

[magit]: https://magit.vc/
[Nix]: https://nixos.org/nix/
[code review]: ./REVIEWS.md
[Conventional Commits]: https://www.conventionalcommits.org
[Importing projects into depot]: ./importing-projects.md
[direnv]: https://direnv.net
