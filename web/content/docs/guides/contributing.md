---
title: "Contributing"
description: ""
summary: ""
date: 2025-03-14T14:14:35+01:00
lastmod: 2025-03-21T14:12:42+00:00
draft: false
weight: 12
toc: true
---

You want to start contributing? Nice!

We do use [Gerrit](https://www.gerritcodereview.com) for Code Review.
It allows a more granular review (per-commit granularity rather than PR
granularity), as well as keeping track as how commits change over time.
It greatly simplifies the review process, and leads to overall more high-quality
contributions.

While it might initially look a bit intimidating, you hopefully will spend less
time learning its workflow than writing actual Snix code.
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon icon-tabler icons-tabler-outline icon-tabler-mood-wink-2"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 21a9 9 0 1 1 0 -18a9 9 0 0 1 0 18z" /><path d="M9 10h-.01" /><path d="M14.5 15a3.5 3.5 0 0 1 -5 0" /><path d="M15.5 8.5l-1.5 1.5l1.5 1.5" /></svg>

{{<callout>}}
This assumes you have the repo already cloned and the necessary tools installed
as described in [Building Snix]({{< relref "./building" >}}), so make sure you
went through these instructions first.
{{</callout>}}

### Creating a Gerrit account
 - Navigate to [our Gerrit instance][snix-gerrit]. Hit the "Sign in" button
   (which allows SSO with some common IdPs)
 - In the User settings, paste an SSH public key and hit the "Add New SSH key"
   button. [^1]
 - Alternatively, you can also create "HTTP Credentials" (though saving the HTTP
   password is messy).

### Update your git remote URL
Instead of trying to push to Forgejo, reconfigure your git remote URL to
interact with Gerrit directly.

Replace `$USER` with your `Username` shown in the Gerrit settings.

#### If using SSH authentication:
```console
$ git remote set-url origin "ssh://$USER@cl.snix.dev:29418/snix"
```


#### If using HTTP authentication:
```console
$ git remote set-url origin "https://$USER@cl.snix.dev/a/snix"
```

<!-- TODO: fix replication to include refs/changes/… etc, and ensure it
replicates fast enough, then update to --push only -->

### Install the commit-msg hook
Gerrit uses a `commit-msg` hook to add a `Change-Id: …` field to each commit
message if not present already. This allows Gerrit to identify new revisions /
updates of old commits, and track them as new revisions of the same "CL" [^2].

To install the commit-msg hook, run the following from the repo root:

```console
$ mkdir -p .git/hooks
$ curl -Lo .git/hooks/commit-msg https://cl.snix.dev/tools/hooks/commit-msg
$ chmod +x .git/hooks/commit-msg
```

{{< callout context="tip" title="Did you know?" icon="outline/rocket" >}}
Gerrit refuses receiving commits without these `Change-Id: …` fields.

If you already have some local commits without `Change-Id` field, `git commit
--amend` them after installing the `commit-msg` hook to add them.
{{< /callout >}}

### Push your changes
Do some local changes, and push them to Gerrit as follows:

```console
$ git push origin HEAD:refs/for/canon
```

Gerrit will print links to newly created CLs to your terminal.

If you want to update/edit your CL, simply squash these changes into your local
commit and push again.

### The Gerrit model
If do not have experience with the Gerrit, consider reading the
[<cite>Working with Gerrit: An example</cite>][Gerrit Walkthrough] or
[<cite>Basic Gerrit Walkthrough — For GitHub Users</cite>][gerrit-for-github-users].

Some more tips:

 * Assign a reviewer to review your changes.
 * React on comments and mark them as resolved once you did.
   * Comments are only "Drafts" (stored server-side) until you send them off.
     This can be done by the `Reply` button on the top, for example.
 * Once CI is green, it's up to the *Author* of the CL to submit, not the
   reviewer.
   If you want a bot to automatically submit in this case, you can add the
   `Autosubmit+1` label.
 * Rebase on `origin/canon` regularly. You cannot push if you still have an old
   version of a now-submitted CL in your git log.

{{< callout context="tip" title="Did you know?" icon="outline/rocket" >}}
You can immediately assign reviewers and other fields while pushing a
new/updated change, by adding it to the push URL.

```console
$ git push origin HEAD:refs/for/canon%r=alice,cc=bob,l=Autosubmit+1,publish-comments
```
 * will set `alice` as a reviewer
 * will set `bob` as CC
 * adds the `Autosubmit+1` label
 * publishes any outstanding draft comments
{{< /callout >}}


[snix-gerrit]: https://cl.snix.dev
[Gerrit walkthrough]: https://gerrit-review.googlesource.com/Documentation/intro-gerrit-walkthrough.html
[gerrit-for-github-users]: https://gerrit.wikimedia.org/r/Documentation/intro-gerrit-walkthrough-github.html
[^1]: currently, `ssh-*-sk` keytypes are not supported, so use an `ssh-ed25519` key.
[^2]: abbreviation for "change list", and the review unit in Gerrit.

### Commit conventions

#### Commit messages

The following described way of writing commit messages is known as [Conventional Commits][] and
should bring these advantages:

* automatic creation of changelogs from commit messages
* lean commits: one focused change per commit
* filtering of commit history by type

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

And `scope` should refer to some kind of logical grouping inside of the project.

It does not make sense to include the full path unless it aids in
disambiguating. For example, when changing `/snix/eval/src/lib.rs` it is enough to write `feat(eval): ...`.

Please take a look at the existing [commit history][] for examples.

#### Commit content

Multiple changes should be divided into multiple git commits whenever possible.
Common sense applies.

#### Code quality

This one should go without saying - but please ensure that your code quality
does not fall below the rest of the project. This is of course very subjective,
but as an example if you place code that throws away errors into a block in
which errors are handled properly your change might be rejected.

[commit history]: https://git.snix.dev/snix/snix/commits/branch/canon
[Conventional Commits]: https://www.conventionalcommits.org
