#!/usr/bin/env bash
# Print the CHANGELOG.md section for a given version, suitable for use as
# GitHub Release notes.
#
# Usage:
#   bash macos/scripts/extract-changelog-section.sh 1.2.0
#
# Prints to stdout the lines from "## v1.2.0 ..." (heading skipped) up to —
# but not including — the next "## " heading. The CI release workflow pipes
# this into the action-gh-release `body:` field so the GitHub Release page
# shows the same prose that the in-repo CHANGELOG carries, with no
# duplicate authoring.
#
# Exits 2 with a clear message if the section is missing (catches
# "developer forgot to add a CHANGELOG entry for the new tag" before the
# release ships).

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version>   (e.g. 1.2.0)" >&2
    exit 2
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "error: $CHANGELOG not found" >&2
    exit 2
fi

# Escape dots in the version so the regex matches them literally — without
# this, "1.2.0" would also match "1A2A0" (regex `.` is any char).
ESCAPED="${VERSION//./\\.}"

# Walk the file top-down. Turn on the print flag when we hit the matching
# version heading; turn it off at the next `## ` heading (covers older
# version sections AND a future "## Unreleased" placed below the latest
# release). The matched heading itself isn't printed — GitHub auto-titles
# the release "v<version>" so repeating it in the body is noise.
section=$(awk -v ver="$ESCAPED" '
    $0 ~ "^## v" ver "([ ]|$)" { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section { print }
' "$CHANGELOG")

if [[ -z "$section" ]]; then
    echo "error: no section for v$VERSION found in $CHANGELOG" >&2
    echo "       Expected a heading of the form: ## v$VERSION — title" >&2
    exit 2
fi

# GitHub's markdown renderer collapses leading/trailing blank lines on its
# own, so we emit the section as-is and don't try to trim. (An earlier
# trim attempt with `print buf` inserted a stray newline between every
# pair of output lines because `print ""` still emits a newline — the
# rendered notes had a blank line between every paragraph, including
# within bulleted lists. Simpler: just don't trim.)
printf '%s\n' "$section"
