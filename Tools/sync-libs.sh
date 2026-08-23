#!/usr/bin/env bash
# ============================================================
# SYNC EMBEDDED LIBS
# ------------------------------------------------------------
# DandersUI is a LibStub library, not an addon. The canonical source is
# <repo>/DandersUI; every host addon ships its own copy at
# <host>/Libs/DandersUI/ and loads it from its TOC. Those copies are
# git-ignored: locally they are junctions to the canonical folder, and in CI
# this script makes them real copies so the packager has something to zip.
#
# Never edit a copy under */Libs/DandersUI -- edit <repo>/DandersUI and re-run
# this.
#
# Idempotent: a copy that is a junction/symlink is left alone (it already
# tracks the source), a plain directory is refreshed in place, and a missing
# one is created.
#
# Usage: bash Tools/sync-libs.sh      (from the repo root, or anywhere)
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/DandersUI"
HOSTS="DandersFrames DandersMover"

if [ ! -d "$SRC" ]; then
    echo "sync-libs: canonical source not found at $SRC" >&2
    exit 1
fi

for HOST in $HOSTS; do
    DEST="$REPO_ROOT/$HOST/Libs/DandersUI"

    if [ ! -d "$REPO_ROOT/$HOST" ]; then
        echo "sync-libs: no such host folder: $HOST -- skipped" >&2
        continue
    fi

    if [ -L "$DEST" ] || [ -n "$(readlink "$DEST" 2>/dev/null || true)" ]; then
        echo "sync-libs: $HOST/Libs/DandersUI is a link -- left as is"
        continue
    fi

    if [ -d "$DEST" ]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete "$SRC/" "$DEST/"
            echo "sync-libs: refreshed $HOST/Libs/DandersUI"
        else
            # No rsync (Git Bash). Copy over the top: files the source no
            # longer has are left behind, which is why CI uses rsync.
            cp -r "$SRC/." "$DEST/"
            echo "sync-libs: copied over $HOST/Libs/DandersUI (no rsync -- stale files not pruned)"
        fi
    else
        mkdir -p "$REPO_ROOT/$HOST/Libs"
        cp -r "$SRC" "$DEST"
        echo "sync-libs: created $HOST/Libs/DandersUI"
    fi
done
