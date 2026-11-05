#!/usr/bin/env bash
# ============================================================
# SYNC THE STANDALONE DANDERSMOVER REPO
# ------------------------------------------------------------
# DandersFrames is the source of truth. This publishes the current DandersMover/
# to its own repo, with DandersMover at that repo's root.
#
# SNAPSHOTS, NOT HISTORY. The standalone repo starts fresh and gets one commit per
# sync, so none of this repo's commit messages or old files reach it. That's why
# nothing here uses `git subtree split`, and why the commit message is fixed rather
# than copied from the commits being published.
#
# ONE-WAY. Anything committed directly to the standalone repo is overwritten by the
# next sync. To take a fix from there, port it here first:
#   git cherry-pick -Xsubtree=DandersMover <sha>
#
# Each snapshot also gets a real copy of DandersUI at Libs/DandersUI. Here it is a
# git-ignored junction, and without it the addon dies at its LibStub lookup.
#
# Never creates releases or tags: CurseForge and GitHub uploads stay in release.yml.
#
# Usage:  bash Tools/sync-mover-repo.sh <standalone repo url or path>
# ============================================================
set -euo pipefail

MIRROR="${1:?usage: sync-mover-repo.sh <standalone repo url or path>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$MIRROR" "$WORK"
# Danders' private GitHub noreply address. Not a bare noreply@ address: GitHub links
# that to a stranger's account and lists them as a contributor.
git -C "$WORK" config user.name "Danders"
git -C "$WORK" config user.email "241103671+DanderBot@users.noreply.github.com"
# An empty repo clones onto whatever the local default branch is called.
git -C "$WORK" symbolic-ref HEAD refs/heads/main

# Clear the old snapshot first, so a file deleted here is deleted there too.
git -C "$WORK" rm -r --quiet --force --ignore-unmatch .

# Tracked files at HEAD only, so a local junction or stray file can't get in.
git -C "$REPO_ROOT" archive HEAD:DandersMover | tar -x -C "$WORK"
mkdir -p "$WORK/Libs/DandersUI"
git -C "$REPO_ROOT" archive HEAD:DandersUI | tar -x -C "$WORK/Libs/DandersUI"
# The kit's developer notes aren't addon files.
rm -f "$WORK/Libs/DandersUI/README.md"

git -C "$WORK" add -A
if git -C "$WORK" diff --cached --quiet; then
    echo "sync-mover: nothing changed at $SOURCE_SHA"
    exit 0
fi

git -C "$WORK" commit --quiet -m "Sync from DandersFrames $SOURCE_SHA"
git -C "$WORK" push --quiet origin main
echo "sync-mover: pushed $(git -C "$WORK" rev-parse --short HEAD) to main"
