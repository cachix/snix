Contribution Guidelines
=======================

<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Contribution Guidelines](#contribution-guidelines)
  - [Before making a change](#before-making-a-change)
  - [Builds \& tests](#builds--tests)
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
[Importing projects into depot]: ./importing-projects.md
[direnv]: https://direnv.net
