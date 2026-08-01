#!/usr/bin/env bash
# generate_changelog.sh — Reads CHANGELOG.md and generates the addon Changelog.lua
# Called by GitHub Actions before packaging.

set -euo pipefail

CHANGELOG_FILE="CHANGELOG.md"
# Core/ since the 2026-07 folder reorg. release.yml greps this same path for the
# release channel and skips builds that only touch it — keep all three in step.
#
# Two outputs since the LoadOnDemand split: the resident file carries only the
# stamped BUILD_DATE/RELEASE_CHANNEL header; the ~180 KB changelog text goes to
# the companion, which is the only thing that ever reads it. release.yml's
# build-skip filter lists BOTH paths.
OUTPUT_FILE="DandersFrames/Core/Changelog.lua"
OUTPUT_TEXT_FILE="DandersFrames_Options/Changelog.lua"

if [ ! -f "$CHANGELOG_FILE" ]; then
    echo "Error: $CHANGELOG_FILE not found."
    exit 1
fi

# Build date
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ============================================================
# SEMVER HELPERS
# ============================================================

# Extract major.minor.patch from a version string (v1.2.3, v1.2.3-beta.1, etc.)
parse_major() { echo "${1#v}" | cut -d. -f1; }
parse_minor() { echo "${1#v}" | cut -d. -f2 | cut -d- -f1; }

# Check if the version bump is minor or major
is_minor_or_major_bump() {
    local cur_major; cur_major=$(parse_major "$1")
    local cur_minor; cur_minor=$(parse_minor "$1")
    local prev_major; prev_major=$(parse_major "$2")
    local prev_minor; prev_minor=$(parse_minor "$2")

    [ "$cur_major" != "$prev_major" ] || [ "$cur_minor" != "$prev_minor" ]
}

# Extract only the header + first ## [x.y.z] section from CHANGELOG.md
trim_to_first_section() {
    echo "$1" | awk '/^## \[/ { count++ } count <= 1 { print }'
}

# Check if CHANGELOG.md has a curated section for an unreleased version.
# Returns 0 (true) if the first ## [x.y.z] section has no matching stable tag,
# meaning the user wrote a changelog entry for a version that hasn't shipped yet.
# When true, we skip auto-prepending raw commit messages.
has_curated_changelog() {
    local first_ver
    first_ver=$(grep -m1 '^## \[' "$CHANGELOG_FILE" | sed 's/^## \[\([0-9.]*\)\].*/\1/' || echo "")
    if [ -z "$first_ver" ]; then
        return 1
    fi
    # If a stable release tag (no pre-release suffix) exists for this version,
    # it's a released section — not curated for an upcoming build
    if git tag -l "v${first_ver}" 2>/dev/null | grep -q "^v${first_ver}$"; then
        return 1
    fi
    return 0
}

# ============================================================
# DETERMINE VERSION AND CHANGELOG CONTENT
# ============================================================
if [ -n "${OVERRIDE_TAG:-}" ]; then
    CURRENT_TAG="$OVERRIDE_TAG"
else
    CURRENT_TAG=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
fi
LAST_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || echo "v0.0.0")

# Branch pushes must always produce alpha builds, even if a tag exists on HEAD
if [ "${FORCE_ALPHA:-}" = "true" ]; then
    CURRENT_TAG=""
fi

if [ -n "$CURRENT_TAG" ]; then
    # Tagged commit — determine channel from tag name
    if echo "$CURRENT_TAG" | grep -qi "beta"; then
        RELEASE_CHANNEL="beta"
    elif echo "$CURRENT_TAG" | grep -qi "alpha"; then
        RELEASE_CHANNEL="alpha"
    else
        RELEASE_CHANNEL="release"
    fi
    VERSION="$CURRENT_TAG"

    # Find previous release tag (excluding current and pre-release tags)
    PREV_RELEASE=$(git tag -l 'v[0-9]*' --sort=-v:refname | grep -v '-' | grep -v "^${CURRENT_TAG}$" | head -n1 || echo "")

    if [ -n "$PREV_RELEASE" ] && is_minor_or_major_bump "$CURRENT_TAG" "$PREV_RELEASE"; then
        # Minor/major bump: only include the latest version section
        CHANGELOG_CONTENT=$(trim_to_first_section "$(cat "$CHANGELOG_FILE")")
        echo "Minor/major bump detected (${PREV_RELEASE} -> ${CURRENT_TAG}): trimmed changelog"
    else
        # Patch or first release: keep full changelog
        CHANGELOG_CONTENT=$(cat "$CHANGELOG_FILE")
    fi

    # Beta builds: prepend unreleased commits since the base release
    # Skip if CHANGELOG.md already has a curated section for this version
    if [ "$RELEASE_CHANNEL" = "beta" ] && [ -n "$PREV_RELEASE" ]; then
        if has_curated_changelog; then
            echo "Curated changelog found — skipping commit prepend for beta"
        else
            UNRELEASED_COMMITS=$(git log "${PREV_RELEASE}..HEAD" --oneline --no-merges 2>/dev/null | grep -v '\[skip ci\]' || echo "")
            if [ -n "$UNRELEASED_COMMITS" ]; then
                UNRELEASED_SECTION="## Unreleased (${VERSION})

$(echo "$UNRELEASED_COMMITS" | sed 's/^[a-f0-9]* /- /')

---
"
                HEADER=$(echo "$CHANGELOG_CONTENT" | head -n 1)
                BODY=$(echo "$CHANGELOG_CONTENT" | tail -n +2)
                CHANGELOG_CONTENT="${HEADER}

${UNRELEASED_SECTION}
${BODY}"
            fi
        fi
    fi
else
    # Untagged commit — alpha build
    RELEASE_CHANNEL="alpha"
    COMMIT_COUNT=$(git rev-list "${LAST_TAG}..HEAD" --count 2>/dev/null || echo "0")
    # Strip pre-release suffix (v1.0.0-beta.3 → v1.0.0) for clean alpha version
    BASE_VERSION=$(echo "$LAST_TAG" | sed 's/-[a-zA-Z].*$//')
    VERSION="${BASE_VERSION}-alpha.${COMMIT_COUNT}"

    # Skip commit prepend if CHANGELOG.md already has a curated section
    if has_curated_changelog; then
        echo "Curated changelog found — skipping commit prepend for alpha"
        CHANGELOG_CONTENT=$(cat "$CHANGELOG_FILE")
    else
        UNRELEASED_COMMITS=$(git log "${LAST_TAG}..HEAD" --oneline --no-merges 2>/dev/null | grep -v '\[skip ci\]' || echo "")

        if [ -n "$UNRELEASED_COMMITS" ]; then
            UNRELEASED_SECTION="## Unreleased (${VERSION})

$(echo "$UNRELEASED_COMMITS" | sed 's/^[a-f0-9]* /- /')

---
"
            HEADER=$(head -n 1 "$CHANGELOG_FILE")
            BODY=$(tail -n +2 "$CHANGELOG_FILE")
            CHANGELOG_CONTENT="${HEADER}

${UNRELEASED_SECTION}
${BODY}"
        else
            CHANGELOG_CONTENT=$(cat "$CHANGELOG_FILE")
        fi
    fi
fi

# Update CHANGELOG.md in working directory so the packager picks up changes
echo "$CHANGELOG_CONTENT" > "$CHANGELOG_FILE"

# Sync TOC version if it doesn't already match (avoids double-bump when manually updated)
#
# ☠ BOTH TOCs. The packager does not rewrite "## Version:" -- its toc_version
# handling is the Interface (game) version, not this field -- so whatever is
# committed here is what WoW shows in the addon list, in the zip and locally
# through a dev junction. Syncing only the main TOC left the companion pinned
# at whatever it was hand-written as, drifting one version further behind on
# every release.
for TOC_FILE in "DandersFrames/DandersFrames.toc" "DandersFrames_Options/DandersFrames_Options.toc"; do
    if [ ! -f "$TOC_FILE" ]; then
        echo "Error: $TOC_FILE not found — the addon layout changed without this script." >&2
        exit 1
    fi
    CURRENT_TOC_VERSION=$(grep '^## Version:' "$TOC_FILE" | sed 's/^## Version: //')
    if [ "$CURRENT_TOC_VERSION" != "$VERSION" ]; then
        sed -i "s/^## Version: .*/## Version: ${VERSION}/" "$TOC_FILE"
        echo "Updated ${TOC_FILE}: ${CURRENT_TOC_VERSION} -> ${VERSION}"
    else
        echo "${TOC_FILE} already matches: ${VERSION}"
    fi
done

# Write the resident header (stamps only -- the addon reads RELEASE_CHANNEL at
# load; the text below never loads unless the settings panel does)
cat > "$OUTPUT_FILE" << LUAEOF
local addonName, DF = ...
DF.BUILD_DATE = "${BUILD_DATE}"
DF.RELEASE_CHANNEL = "${RELEASE_CHANNEL}"
-- The changelog text itself lives in DandersFrames_Options/Changelog.lua:
-- it is a ~180 KB string only the settings panel ever reads, and holding it
-- resident cost every player that memory forever. Both files are GENERATED
-- by generate_changelog.sh -- edit CHANGELOG.md, not either output.
LUAEOF

# Write the companion text. NOTE the DF binding: a companion file's vararg is
# its OWN addon table, so it must take the parent's from the global.
cat > "$OUTPUT_TEXT_FILE" << LUAEOF
-- GENERATED by generate_changelog.sh from CHANGELOG.md -- do not edit.
-- ☠ Companion addon: bind the parent's table from the global it publishes
-- at DandersFrames/Core.lua:9, never \`...\` (which yields THIS addon's table).
local DF = DandersFrames
DF.CHANGELOG_TEXT = [===[
${CHANGELOG_CONTENT}
]===]
LUAEOF

echo "Generated ${OUTPUT_FILE} + ${OUTPUT_TEXT_FILE}: channel=${RELEASE_CHANNEL} date=${BUILD_DATE}"
