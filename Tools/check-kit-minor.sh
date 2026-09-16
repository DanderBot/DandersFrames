#!/usr/bin/env bash
# Refuse a release whose DandersUI changed since the last tag without a MINOR bump.
#
# WHY: DandersUI is embedded by several Danders addons and registered through
# LibStub, which keeps the FIRST copy it sees at a given MINOR and silently
# rejects every later copy at the same number. v5.4.0-alpha.4 shipped a week of
# kit changes at MINOR 13 -- the same 13 an older DandersMover / DandersOppositeCaller
# copy carried -- so on any machine where one of those loaded first, the new
# Frame page never appeared and nothing said why (EXPECTED_MINOR matched, 13 == 13).
#
# Usage: bash Tools/check-kit-minor.sh            (compares against the last v* tag)
#        bash Tools/check-kit-minor.sh <base> [<head>]   (defaults: last v* tag, HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."
base="${1:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD)}"; head="${2:-HEAD}"
minor_at() { git show "$1:DandersUI/Core.lua" | grep -oE 'MINOR = "DandersUI-1.0", [0-9]+' | grep -oE '[0-9]+$'; }
expected_at() { git show "$1:DandersUI/OptionsCore.lua" | grep -oE 'EXPECTED_MINOR = [0-9]+' | grep -oE '[0-9]+$'; }
old=$(minor_at "$base"); new=$(minor_at "$head"); exp=$(expected_at "$head")
# NOTE: `|| true` on the grep. With no kit change at all git diff prints nothing, grep
# matches nothing and exits 1, and `set -euo pipefail` then killed this script before its
# first echo -- a silent exit 1 that reads as "the gate failed" and blocks the release.
# Every release that does not touch DandersUI hit it; alpha.7 only passed because it
# happened to change five kit files.
changed=$(git diff --name-only "$base" "$head" -- DandersUI | { grep -v '^DandersUI/README.md$' || true; } | wc -l | tr -d ' ')
echo "kit-minor: base=$base head=$head minor@base=$old minor@head=$new EXPECTED_MINOR@head=$exp changed-kit-files=$changed"
if [ "$new" != "$exp" ]; then
  echo "ERROR: DandersUI MINOR ($new) and OptionsCore EXPECTED_MINOR ($exp) differ -- the options half goes inert at login." >&2; exit 1
fi
if [ "$changed" -gt 0 ] && [ "$new" -le "$old" ]; then
  echo "ERROR: DandersUI changed in $changed file(s) since $base but MINOR is still $new -- an older embedded copy at $old will win the LibStub race. Bump MINOR and EXPECTED_MINOR." >&2; exit 1
fi
echo "kit-minor: OK"
