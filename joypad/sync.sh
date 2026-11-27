#!/usr/bin/env bash
# Sync the fork with upstream mgba-emu/mgba now, from this clone.
#
# The same rules as .github/workflows/sync-upstream.yml: fast-forward `master` to upstream
# master (never forced; stops if `master` has diverged), then merge it into `remote` with a
# merge commit and push. Nothing is ever force-pushed or rebased.
#
# On a conflict the merge is left in progress on `remote` so you can resolve it: fix the
# files listed, `git add` them, `git commit`, then `git push origin remote`. Or give up with
# `git merge --abort`.
#
# Use it when you want a sync now, or when the workflow is blocked (for example when upstream
# changes .github/workflows/, which the workflow's token may not push; your own login can).
#
# Usage: joypad/sync.sh [--dry-run]
#   --dry-run   fetch and report what would happen; change nothing.

set -euo pipefail

UPSTREAM_URL=https://github.com/mgba-emu/mgba.git
MASTER=master
REMOTE=remote
dry_run=false

case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1 (try --help)" >&2; exit 64 ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'sync: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$(readlink -f "$0")")/.."
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside the mgba-r clone"

git remote get-url upstream >/dev/null 2>&1 || {
  $dry_run && die "remote 'upstream' is missing (add it: git remote add upstream $UPSTREAM_URL)"
  git remote add upstream "$UPSTREAM_URL"
}

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  die "the working tree has uncommitted changes; commit or stash them first"
fi
if [ -e "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  die "a merge is already in progress; finish it (git commit) or abort it (git merge --abort)"
fi

# The daily workflow is the normal path; say so if GitHub has switched it off
# (forks start with schedules off, and 60 days without activity turn them off).
if command -v gh >/dev/null 2>&1; then
  state=$(gh workflow view sync-upstream.yml -R angwdev/mgba-r --json state --jq .state 2>/dev/null || true)
  if [ -n "$state" ] && [ "$state" != "active" ]; then
    say "Warning: the scheduled workflow sync-upstream.yml is '$state'. Enable it: gh workflow enable sync-upstream.yml -R angwdev/mgba-r"
  fi
fi

say "Fetching origin and upstream..."
git fetch --quiet --no-tags origin "+refs/heads/$MASTER:refs/remotes/origin/$MASTER" "+refs/heads/$REMOTE:refs/remotes/origin/$REMOTE"
git fetch --quiet --no-tags upstream "+refs/heads/master:refs/remotes/upstream/master"

up=$(git rev-parse refs/remotes/upstream/master)
master=$(git rev-parse "refs/remotes/origin/$MASTER")
remote=$(git rev-parse "refs/remotes/origin/$REMOTE")
say "upstream master  $up"
say "origin/$MASTER     $master"
say "origin/$REMOTE     $remote"

# 1. master: fast-forward only.
git merge-base --is-ancestor "$master" "$up" ||
  die "origin/$MASTER has commits that are not in upstream master; it must stay an exact copy. Look at: git log upstream/master..origin/$MASTER"

if [ "$master" = "$up" ]; then
  say "$MASTER is equal to upstream master."
elif $dry_run; then
  say "Would fast-forward $MASTER by $(git rev-list --count "$master..$up") commits."
else
  git push origin "$up:refs/heads/$MASTER"
  say "$MASTER fast-forwarded by $(git rev-list --count "$master..$up") commits."
fi
# Keep the local master branch (if any) in step, fast-forward only.
if ! $dry_run && git show-ref --verify --quiet "refs/heads/$MASTER"; then
  if [ "$(git symbolic-ref --short -q HEAD || true)" = "$MASTER" ]; then
    git merge --quiet --ff-only "$up"
  elif git merge-base --is-ancestor "refs/heads/$MASTER" "$up"; then
    git update-ref "refs/heads/$MASTER" "$up"
  fi
fi

# 2. remote: merge upstream if it is not already in.
if git merge-base --is-ancestor "$up" "$remote"; then
  say "$REMOTE already contains upstream master: nothing to merge."
  exit 0
fi
count=$(git rev-list --count "$remote..$up")
base=$(git merge-base "$up" "$remote")
if [ -n "$(git diff --name-only "$base" "$up" -- .github/workflows)" ]; then
  say "Note: upstream changed .github/workflows/; pushing needs your login's 'workflow' scope."
fi
if $dry_run; then
  if git merge-tree --write-tree --quiet "$remote" "$up" >/dev/null 2>&1; then
    say "Would merge $count upstream commits into $REMOTE cleanly."
  else
    say "Would merge $count upstream commits into $REMOTE, with conflicts in:"
    git merge-tree --write-tree --name-only --no-messages "$remote" "$up" | tail -n +2 | sed 's/^/  /'
  fi
  exit 0
fi

start=$(git symbolic-ref --short -q HEAD || git rev-parse HEAD)
if git show-ref --verify --quiet "refs/heads/$REMOTE"; then
  local_remote=$(git rev-parse "refs/heads/$REMOTE")
  if [ "$local_remote" != "$remote" ]; then
    git merge-base --is-ancestor "$local_remote" "$remote" ||
      die "local $REMOTE has commits that are not on origin/$REMOTE; push them first (git push origin $REMOTE)"
  fi
  git switch --quiet "$REMOTE"
  git merge --quiet --ff-only "$remote"
else
  git switch --quiet --create "$REMOTE" --track "origin/$REMOTE"
fi

if ! git merge --no-ff --no-edit -m "Merge upstream master ($(git rev-parse --short "$up")) into $REMOTE" "$up"; then
  say ""
  say "CONFLICT: upstream master could not be merged into $REMOTE. Nothing was pushed to $REMOTE."
  say "Conflicting files:"
  git diff --name-only --diff-filter=U | sed 's/^/  /'
  say ""
  say "The merge is left in progress on branch $REMOTE. To finish it:"
  say "  fix the files, git add <files>, git commit, git push origin $REMOTE"
  say "To give up instead: git merge --abort"
  exit 2
fi

git push origin "$REMOTE"
say "Merged $count upstream commits into $REMOTE ($(git rev-parse --short HEAD)) and pushed."
say "The push starts build-linux.yml, which publishes release remote-$(git rev-parse --short=9 HEAD)."
[ "$start" = "$REMOTE" ] || git switch --quiet "$start" 2>/dev/null || true
