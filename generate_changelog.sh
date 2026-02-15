#!/usr/bin/env bash
# generate_changelog.sh — Reads CHANGELOG.md and generates Changelog.lua
# Called by GitHub Actions before packaging.

set -euo pipefail

CHANGELOG_FILE="CHANGELOG.md"
OUTPUT_FILE="Changelog.lua"

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
    echo "$1" | awk '/^## \[/ { count++; if (count > 1) exit } { print }'
}

# ============================================================
# DETERMINE VERSION AND CHANGELOG CONTENT
# ============================================================
CURRENT_TAG=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
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
    if [ "$RELEASE_CHANNEL" = "beta" ] && [ -n "$PREV_RELEASE" ]; then
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
else
    # Untagged commit — alpha build
    RELEASE_CHANNEL="alpha"
    COMMIT_COUNT=$(git rev-list "${LAST_TAG}..HEAD" --count 2>/dev/null || echo "0")
    # Strip pre-release suffix (v1.0.0-beta.3 → v1.0.0) for clean alpha version
    BASE_VERSION=$(echo "$LAST_TAG" | sed 's/-[a-zA-Z].*$//')
    VERSION="${BASE_VERSION}-alpha.${COMMIT_COUNT}"

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

# Update CHANGELOG.md in working directory so the packager picks up changes
echo "$CHANGELOG_CONTENT" > "$CHANGELOG_FILE"

# Write Changelog.lua
cat > "$OUTPUT_FILE" << LUAEOF
local addonName, DF = ...
DF.ADDON_VERSION = "${VERSION}"
DF.BUILD_DATE = "${BUILD_DATE}"
DF.RELEASE_CHANNEL = "${RELEASE_CHANNEL}"
DF.CHANGELOG_TEXT = [===[
${CHANGELOG_CONTENT}
]===]
LUAEOF

# Pre-set TOC version for alpha builds so the packager uses our clean version
# For tagged builds, the packager replaces @project-version@ with the tag name
if [ "$RELEASE_CHANNEL" = "alpha" ]; then
    sed -i "s/@project-version@/${VERSION}/" DandersFrames.toc
    echo "Pre-set TOC version to ${VERSION}"
fi

echo "Generated ${OUTPUT_FILE}: version=${VERSION} channel=${RELEASE_CHANNEL} date=${BUILD_DATE}"
