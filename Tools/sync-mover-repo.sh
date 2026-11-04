#!/usr/bin/env bash
# ============================================================
# SYNC THE STANDALONE DANDERSMOVER REPO
# ------------------------------------------------------------
# DandersFrames is the source of truth. This copies DandersMover/, with its
# history, to its own repo, with DandersMover at that repo's root.
#
# ONE-WAY. Anything committed directly to the standalone repo never comes back
# here on its own: to take a fix from there, cherry-pick it with
#   git cherry-pick -Xsubtree=DandersMover <sha>
#
# Two layers on the standalone repo's main:
#   1. The split history, merged in. `git subtree split` gives the same hashes
#      for the same input, so each merge only brings the new commits.
#   2. A real copy of DandersUI at Libs/DandersUI. Here it is a git-ignored
#      junction, so the split can't carry it, and without it the addon dies at
#      its LibStub lookup. That's why the split isn't simply force-pushed.
#
# Never creates releases or tags: CurseForge and GitHub uploads stay in
# release.yml.
#
# Usage:  bash Tools/sync-mover-repo.sh <standalone repo url or path>
# Needs full history (fetch-depth: 0). MOVER_SPLIT_SHA skips the split when the
# result is already known, because it takes minutes on Windows.
# ============================================================
set -euo pipefail

MIRROR="${1:?usage: sync-mover-repo.sh <standalone repo url or path>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
SPLIT="${MOVER_SPLIT_SHA:-$(git -C "$REPO_ROOT" subtree split --quiet --prefix=DandersMover HEAD)}"
echo "sync-mover: $SOURCE_SHA splits to $SPLIT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$MIRROR" "$WORK"
git -C "$WORK" config user.name "DandersFrames sync"
git -C "$WORK" config user.email "noreply@users.noreply.github.com"

git -C "$REPO_ROOT" push --quiet "$WORK" "$SPLIT:refs/heads/mover-split"

if git -C "$WORK" rev-parse --quiet --verify HEAD >/dev/null; then
    git -C "$WORK" merge --quiet --no-edit -m "Sync from DandersFrames $SOURCE_SHA" mover-split
else
    git -C "$WORK" checkout --quiet -B main mover-split
fi

# Tracked files at HEAD only, so a local junction or stray file can't get in.
rm -rf "$WORK/Libs/DandersUI"
mkdir -p "$WORK/Libs/DandersUI"
git -C "$REPO_ROOT" archive HEAD:DandersUI | tar -x -C "$WORK/Libs/DandersUI"

git -C "$WORK" add -A Libs/DandersUI
if ! git -C "$WORK" diff --cached --quiet; then
    git -C "$WORK" commit --quiet -m "Sync DandersUI from DandersFrames $SOURCE_SHA"
fi

git -C "$WORK" push --quiet origin main
echo "sync-mover: pushed $(git -C "$WORK" rev-parse --short HEAD) to main"
