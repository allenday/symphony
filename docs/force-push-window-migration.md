# Force-Push Window Migration Runbook

Use this runbook when maintainers are about to rewrite shared branch history and downstream clones,
feature branches, forks, or open pull requests need to be realigned safely.

## Scope

This guide covers four common recovery paths after a coordinated force-push window:

- local clones that should exactly match the rewritten upstream branch
- local feature work that must be rebased onto the rewritten branch
- personal forks that need their default branch resynced to upstream
- open work that should be preserved by cherry-picking specific commits instead of replaying old history

## Before The Window

Operators should publish the exact rewrite target before anyone takes action:

- repository URL and branch name being rewritten
- freeze start time and expected end time in UTC
- old tip commit that will be replaced
- new tip commit that consumers should reset or rebase onto
- whether contributors should pause merging until branch protection and CI recover

Recommended announcement template:

```text
We are rewriting <repo>:<branch> during the force-push window starting at <utc timestamp>.
Old tip: <old_sha>
New tip after rewrite: <new_sha>
Do not push to the old branch history during the window.
Wait for the all-clear before resuming normal merges.
```

## Fast Safety Check

Run these commands before modifying a local clone:

```bash
git remote -v
git status --short --branch
git log --oneline --decorate --max-count=5
git fetch origin --prune
```

If the checkout has uncommitted changes, either commit them to a scratch branch or stash them first.
Do not hard-reset a dirty working tree unless the owner has explicitly approved losing those edits.

## Path 1: Reset A Local Clone To The Rewritten Upstream

Use this when the local branch should match upstream exactly and no local commits need to survive.

```bash
git fetch origin --prune
git checkout main
git branch backup/pre-force-push-$(date -u +%Y%m%d%H%M%S) HEAD
git reset --hard origin/main
```

Notes:

- replace `main` with the rewritten shared branch if needed
- the backup branch keeps a pointer to the pre-reset state in case recovery is needed later
- `git clean -fd` should only be used if the owner wants untracked files removed too

## Path 2: Rebase Local Feature Work Onto The Rewritten Branch

Use this when a contributor has local commits that should stay on top of the new upstream history.

```bash
git fetch origin --prune
git checkout <feature-branch>
git branch backup/<feature-branch>-pre-rewrite
git rebase --onto origin/main <old_base_sha> <feature-branch>
```

If the old base commit is unknown, derive it from the fork point or merge-base:

```bash
git merge-base <feature-branch> origin/main
git reflog show --date=iso <feature-branch>
```

During conflict resolution:

- resolve files intentionally, not by blanket checkout of one side
- run the relevant tests before continuing
- use `git rebase --continue` after each resolved stop
- use `git rebase --abort` if the replay is clearly wrong and switch to cherry-pick recovery instead

After a successful rebase:

```bash
git log --oneline --decorate origin/main..HEAD
git push --force-with-lease origin <feature-branch>
```

Use `--force-with-lease`, not plain `--force`, so the push fails if someone else advanced the branch.

## Path 3: Sync A Personal Fork With Upstream

Use this when a downstream fork tracks the rewritten repository and its default branch must be updated.

Add the upstream remote if it does not already exist:

```bash
git remote add upstream <upstream-url>
git fetch upstream --prune
```

Reset the fork's default branch to the rewritten upstream branch:

```bash
git checkout main
git branch backup/fork-main-pre-rewrite-$(date -u +%Y%m%d%H%M%S) HEAD
git reset --hard upstream/main
git push --force-with-lease origin main
```

If the fork hosts active pull-request branches, rebase or cherry-pick those branches separately before
forcing the fork default branch.

## Path 4: Recover Work By Cherry-Picking Specific Commits

Use this when replaying the old branch shape is risky, the rebase is too noisy, or only a subset of
commits should survive the rewrite.

Identify the commits to keep:

```bash
git log --oneline <old_tip>..<old_feature_branch>
```

Apply them onto a fresh branch from the rewritten upstream:

```bash
git fetch origin --prune
git checkout -b <new-feature-branch> origin/main
git cherry-pick <commit_sha_1> <commit_sha_2> <commit_sha_3>
```

Guidance:

- cherry-pick in dependency order, usually oldest to newest
- prefer `git cherry-pick -x` if downstream traceability matters
- stop and rerun focused tests after each risky conflict
- if a commit only partially applies, split the recovery into smaller picks or manual follow-up commits

## Open Pull Requests During The Window

For maintainers:

- update the PR description or a maintainer comment with the rewrite notice and new base SHA
- ask authors to rebase or cherry-pick onto the new base before further review
- close and replace stale PRs if the branch history no longer maps cleanly to the rewritten base

For contributors:

- do not merge the old PR branch back into the rewritten branch to "fix" divergence
- prefer rebase plus `push --force-with-lease` when the branch should stay the same PR
- prefer a new branch and PR when the recovered commits materially differ from the old review thread

## Rollout Communications Checklist

Use this checklist for the coordinated force-push window:

- confirm the old SHA, new SHA, affected branches, and freeze window owner
- announce the freeze start time and expected recovery window in UTC
- tell contributors to stop pushing to the affected branch until the all-clear
- publish the exact recovery guidance link for reset, rebase, fork sync, and cherry-pick paths
- post the new SHA immediately after the force-push completes
- confirm CI, branch protections, and required automation are healthy on the rewritten tip
- call out any open PRs that need manual author action
- send the all-clear message once pushes and reviews can resume
- keep the old SHA in the announcement thread so downstream teams can recover lost references

Recommended all-clear template:

```text
The force-push window for <repo>:<branch> is complete.
New tip: <new_sha>
CI and branch protections are healthy again.
Resume normal work. If your branch diverged, use the migration runbook:
<link to this document>
```

## Verification

After completing a migration, verify the local branch shape before pushing:

```bash
git status --short --branch
git log --oneline --decorate --graph --max-count=15
git rev-list --left-right --count origin/main...HEAD
```

Expected outcomes:

- reset path: local branch matches upstream with zero divergence
- rebase path: only intended local commits remain ahead of the new upstream base
- fork sync path: fork default branch points at the same commit as upstream
- cherry-pick path: the recovered branch contains only the selected commits
