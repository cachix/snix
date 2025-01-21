TVL Code Reviews
================

<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [TVL Code Reviews](#tvl-code-reviews)
    - [Registration](#registration)
    - [Gerrit setup](#gerrit-setup)
    - [Gerrit workflows](#gerrit-workflows)
    - [Review process & approvals](#review-process--approvals)
    - [Submitting changes via email](#submitting-changes-via-email)
    - [Gerrit for GitHub users](#gerrit-for-github-users)

<!-- markdown-toc end -->


This document describes the TVL code review process & tooling. If you are
looking for general contribution guidelines, please look at the [general
contribution guidelines](./CONTRIBUTING.md).

All changes are tracked at [cl.tvl.fyi](https://cl.tvl.fyi) using Gerrit. See
[Registration](#registration) for information on how to register an account.

## Registration

The preferred method of contributions & review is done via Gerrit.

TVL’s Gerrit supports single sign-on (SSO) using a GitHub, StackOverflow or
GitLab.com account.

Additionally, if you prefer not to use an SSO option or wish to have a
backup authentication strategy in the event of downed server or a keycloak
issue (recommended), you can create a TVL-specific LDAP account on the Gerrit
instance by following these instructions:

1. Be a member of `#tvl` on [hackint][].
2. Clone the depot locally (via `git clone "https://cl.tvl.fyi/depot"`).
3. Create a user entry in our LDAP server in [ops/users][ops-users].

   The entry can be generated using [//web/pwcrypt](https://signup.tvl.fyi/).
4. Create a commit adding yourself (see e.g.
   [CL/2671](https://cl.tvl.fyi/c/depot/+/2671))
5. If only using LDAP, submit the patch via email (see
   [Submitting changes via email](#submitting-changes-via-email))

## Gerrit setup

Gerrit uses the concept of change IDs to track commits across rebases and other
operations that might change their hashes, and link them to unique changes in
Gerrit.

First, [tell Gerrit][Gerrit SSH] about your SSH keys.

Then, to make using Gerrit smooth for users, the repository should be cloned and
a commit hook installed as follows:

```
git clone "ssh://$USER@code.tvl.fyi:29418/depot"
curl -Lo depot/.git/hooks/commit-msg https://cl.tvl.fyi/tools/hooks/commit-msg
chmod +x depot/.git/hooks/commit-msg
```

If you have a previous clone of the depot via HTTP you can use `git remote
set-url` to update the origin URL and install the hook in the same way as above.

## Gerrit workflows

The developer workflow on Gerrit is quite different from what GitHub-users are
used to.

Instead of pushing changes to remote branches, all changes have to be pushed to
`refs/for/canon`. For each commit that is pushed there, a change request is
created automatically.

Changes should usually be based on the remote `HEAD` (the `canon` branch).

Every time you create a new commit the change hook will insert a unique
`Change-Id` tag into the commit message. Once you are satisfied with the state
of your commit and want to submit it for review, you push it to a git ref called
`refs/for/canon`. This designates the commits as changelists (CLs) targeted for
the `canon` branch.

Sending a change for review is done by pushing to a special target. You can set
this to be the default push target through your git configuration:

```
git config remote.origin.url "ssh://$USER@code.tvl.fyi:29418/depot"
git config remote.origin.push HEAD:refs/for/canon
```

Then, after making your change, push to the default, or to a special target:

```
# Example:
git commit -m 'docs(REVIEWS): Fixed all the errors in the reviews docs'
git push origin

# Uploading a work-in-progress CL:
git push origin HEAD:refs/for/canon%wip
```

TIP: Every individual commit will become a separate change. We do not squash
related commits, but instead submit them one by one. Be aware that if you are
expecting a different behaviour and attempt something like an unsquashed subtree
merge, you will produce a *lot* of CLs. This is strongly discouraged.

During your review, the reviewer(s) might ask you to make changes. You can
simply amend your commit(s) and push to the same ref. Gerrit will automatically
update your changes.

Read more about the Gerrit workflow in the [Gerrit walkthrough][].

## Review process & approvals

Each user has the ability to create their own users directory in
`//users/<username>` in which they can submit code without review from other
contributors (they will still need to +2 their own changes, and the initial
check-in of the `OWNERS` file needs to be reviewed).

You can set a directory like this up for yourself by proposing a change similar
to [CL/246](https://cl.tvl.fyi/c/depot/+/246).

For all paths outside of `//users`, code review is required. We have no strict
guidelines about the review process itself, as we're not a megacorp, but we have
formalised checks before submitting:

* At least one person who is [an owner][OWNERS] of the codepath must have given
  a +2 review
* The commit message must conform to our [guidelines][]
* No code review comments must be left unresolved

If all these conditions are fulfilled, the **change author submits their change
themselves**.

## Submitting changes via email

Please keep in mind this process is more complicated and requires more work from
both sides:

 - Someone needs to relay potential comments from Gerrit to you, you won't get
   emails from Gerrit.
 - Uploading new revisions needs to be done by the person sending it to Gerrit
   on your behalf.
 - If you decide to get a Gerrit account later on, existing CLs need to be
   abandoned and recreated (as CLs can't change Owner).
   This causes earlier reviews to be more disconnected, and thus more churn.

We provide local accounts and do SSO with various third-parties, so getting the
account should usually be low-friction.

If you still decide differently, you can submit a patch via email to
`depot@tvl.su` and it will be added to Gerrit by a contributor.

Create an appropriate commit locally and send it us using either of these options:

* `git format-patch`: This will create a `.patch` file which you should email to
  us.
* `git send-email`: If configured on your system, this will take care of the
  whole emailing process for you.

The email address is a [public inbox][].

## Gerrit for GitHub Users

There is a walkthrough that describes [only the parts that differ
from GitHub][github-diff], although it does not cover [attention
sets][], which are important to understand.

### Attention Sets

The attention set of a CL is somewhat similar to the set of GitHub
users who have unread notifications for a PR.  The "your turn" list
on the dashboard is similar to your unread notifications list in
GitHub.  These similarities are only rough approximations, however.

Unfortunately the rules for updating attention sets are very
different and complex.  If you don't read and understand them, you
may end up leaving comments that nobody ever finds out about.  Here
are a few unexpected features:

- Voting on or replying to a CL will remove you from the attention
  set.  You can also do this by clicking on the gray chevron shape
  next to your name.

- If you comment on a merged or abandoned change without marking
  your comment "unresolved", *nobody will be notified of your
  comment*.  If you want to the owner of a merged or abandoned
  change to read your comment, you must mark it as "unresolved" or
  manually add them to the attention set by hovering your mouse over
  their name and clicking "add to attention set"

There are many more [rules][attention-set-rules], which you should
read.


[Gerrit SSH]: https://cl.tvl.fyi/settings/#SSHKeys
[Gerrit walkthrough]: https://gerrit-review.googlesource.com/Documentation/intro-gerrit-walkthrough.html
[OWNERS]: https://cl.tvl.fyi/plugins/owners/Documentation/config.md
[guidelines]: ./CONTRIBUTING.md#commit-messages
[ops-users]: ../ops/users/default.nix
[public inbox]: https://inbox.tvl.su/depot/
[hackint]: https://hackint.org
[github-diff]: https://gerrit.wikimedia.org/r/Documentation/intro-gerrit-walkthrough-github.html
[attention sets]: https://gerrit-review.googlesource.com/Documentation/user-attention-set.html
[attention-set-rules]: https://gerrit-review.googlesource.com/Documentation/user-attention-set.html#_rules
