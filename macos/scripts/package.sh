#!/usr/bin/env bash
# Build the HexEditor plugin and produce the distribution .zip ready to
# upload to a GitHub Release. Wraps the CMake POST_BUILD packaging step in
# macos/CMakeLists.txt (the single source of truth for version, dylib,
# .strings, and PNGs that go into the archive).
#
# Run from the repo root:
#   bash macos/scripts/package.sh
#
# Verifies four things before printing the zip path; aborts loudly if any
# check fails. This is the safety net for the v1.1.0 incident, where a
# stale May-1 zip was uploaded to a May-6 release tag because the original
# script just ran `cmake --build` (which no-ops if nothing changed) and
# `ls -t | head -n 1` returned the leftover zip.
#
# Checks:
#   1. Source HEX_PLUGIN_VERSION_STRING parses to a non-empty value.
#   2. The zip filename matches the source version.
#   3. The zip mtime is newer than this script's start (proves THIS run
#      produced it, not a leftover from an earlier session).
#   4. The dylib inside the zip embeds the same version string at compile
#      time (catches the "compile define wasn't refreshed" failure mode).
#
# Additionally: forces `cmake --build --clean-first` so a stale dylib from
# a previous version can't survive into the new zip. Costs +1-2 min vs. an
# incremental build, but releases are infrequent and silent staleness is
# the worse failure mode.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/macos/build"

# Wall-clock timestamp at script start. Used as the freshness floor for the
# produced zip: a zip older than this can only be a leftover.
INVOKE_START=$(date +%s)

# ---- Read the source's intended version ----------------------------------

if [[ ! -f "${REPO_ROOT}/macos/CMakeLists.txt" ]]; then
    echo "error: macos/CMakeLists.txt not found; run from the repo's parent of macos/" >&2
    exit 2
fi
SOURCE_VERSION=$(grep -E '^set\(HEX_PLUGIN_VERSION_STRING' "${REPO_ROOT}/macos/CMakeLists.txt" \
                 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$SOURCE_VERSION" ]]; then
    echo "error: could not read HEX_PLUGIN_VERSION_STRING from macos/CMakeLists.txt" >&2
    echo "       Expected a line of the form: set(HEX_PLUGIN_VERSION_STRING \"x.y.z\")" >&2
    exit 2
fi
# Reject version values that wouldn't compile as a sensible C string literal —
# notably the in-development "1.1.x" placeholder. A release zip must carry a
# numeric version.
if [[ ! "$SOURCE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: HEX_PLUGIN_VERSION_STRING='$SOURCE_VERSION' is not a numeric x.y.z." >&2
    echo "       This is the in-development placeholder. Bump it to the release version" >&2
    echo "       in macos/CMakeLists.txt before packaging." >&2
    exit 2
fi

# ---- Wipe prior zips + dist-staging so a leftover can't pass through -----

# rm both the version-stamped zip we're about to produce AND any other
# stale zips (older versions, in-dev placeholders) in the build dir.
rm -f "${BUILD_DIR}"/nppHexEditorPlugin-*.zip
rm -rf "${BUILD_DIR}/dist-staging"

# ---- Force a clean rebuild so a stale dylib can't survive ----------------
#
# Without `--clean-first`, `cmake --build` is incremental: if the .mm
# files haven't been touched since the last successful build, the dylib
# isn't relinked and POST_BUILD doesn't fire. The zip would then be
# re-emitted (because we just `rm`'d it) ONLY if POST_BUILD runs — which
# it won't if the target is up-to-date. The clean-first flag forces the
# target to rebuild, which then triggers POST_BUILD, which regenerates the
# zip with the current source's HEX_PLUGIN_VERSION compile define.

echo "==> Building HexEditor (clean) for release packaging…"
cmake --build "${BUILD_DIR}" --target HexEditor --clean-first

# ---- Check 1: the version-stamped zip exists -----------------------------

EXPECTED_ZIP="${BUILD_DIR}/nppHexEditorPlugin-${SOURCE_VERSION}.zip"
if [[ ! -f "$EXPECTED_ZIP" ]]; then
    echo "error: expected zip not produced: ${EXPECTED_ZIP}" >&2
    echo "       HEX_PLUGIN_VERSION_STRING in CMakeLists.txt is '${SOURCE_VERSION}';" >&2
    echo "       the build did not emit a zip with that version. Check the cmake output above." >&2
    exit 2
fi

# ---- Check 2: zip mtime is fresh ----------------------------------------

ZIP_MTIME=$(stat -f %m "$EXPECTED_ZIP")
if (( ZIP_MTIME < INVOKE_START )); then
    echo "error: ${EXPECTED_ZIP} is older than this script's invocation." >&2
    echo "       The dylib was not actually rebuilt — the zip is stale." >&2
    echo "       Reproduce: rm -rf ${BUILD_DIR} && cmake -S macos -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release" >&2
    exit 2
fi

# ---- Check 3: the dylib inside the zip embeds the right version ---------

# Extract the dylib to a temp file, dump its strings to another temp file,
# then grep the dump. We DELIBERATELY don't pipe `strings | grep`: with
# `set -o pipefail`, `grep -q` exits on the first match, `strings` then
# gets SIGPIPE flushing remaining output, and the pipeline as a whole
# reports failure — even though grep itself matched. The CI workflow's
# first run failed exactly this way ("strings: failed to flush output").
# Dumping to a file separates the producer from the consumer so the
# match-then-exit shortcut in grep doesn't interact with strings's I/O.
#
# HEX_PLUGIN_VERSION is a C string defined via target_compile_definitions,
# so it lands in the dylib's __cstring section verbatim. `strings -a`
# walks every section. `grep -xF` matches the line exactly (no regex), so
# we don't have to escape dots and "1.10.0" can't match "1.1.0".
TMP_DYLIB=$(mktemp -t hex_release_check_dylib.XXXXXX)
TMP_STRINGS=$(mktemp -t hex_release_check_strings.XXXXXX)
trap 'rm -f "$TMP_DYLIB" "$TMP_STRINGS"' EXIT
unzip -p "$EXPECTED_ZIP" HexEditor/HexEditor.dylib > "$TMP_DYLIB"
strings -a "$TMP_DYLIB" > "$TMP_STRINGS"

if ! grep -qxF "$SOURCE_VERSION" "$TMP_STRINGS"; then
    echo "error: dylib in ${EXPECTED_ZIP} does not embed HEX_PLUGIN_VERSION='${SOURCE_VERSION}'." >&2
    echo "       The compile define wasn't picked up. Most common cause: the .mm files" >&2
    echo "       weren't recompiled after a CMakeLists version bump because their mtime" >&2
    echo "       was newer than CMakeCache.txt. Wipe the build dir and reconfigure:" >&2
    echo "         rm -rf ${BUILD_DIR}" >&2
    echo "         cmake -S macos -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release" >&2
    echo "         bash macos/scripts/package.sh" >&2
    exit 2
fi

# ---- Sanity check: expected locales are present --------------------------
#
# v1.1.0+ ships 15 .strings files. A zip with significantly fewer is a strong
# signal that stale staging persisted (the v1.1.0 GitHub release zip shipped
# with only 4 locales — the May-1 state before the rest were added).

LOCALE_COUNT=$(unzip -l "$EXPECTED_ZIP" | awk '/Localizable\..*\.strings/ {c++} END {print c+0}')
EXPECTED_LOCALES=15
if (( LOCALE_COUNT < EXPECTED_LOCALES )); then
    echo "error: only ${LOCALE_COUNT} locales in zip (expected ${EXPECTED_LOCALES}+ since v1.1.0)." >&2
    echo "       Stale dist-staging suspected. Inspect: unzip -l ${EXPECTED_ZIP}" >&2
    exit 2
fi

# ---- Success: print zip path + identifying metadata ----------------------

ZIP_SIZE=$(stat -f %z "$EXPECTED_ZIP")
ZIP_SHA=$(shasum -a 256 "$EXPECTED_ZIP" | cut -d' ' -f1)
echo "==> Built nppHexEditorPlugin-${SOURCE_VERSION}.zip"
echo "    Size:    ${ZIP_SIZE} bytes"
echo "    Locales: ${LOCALE_COUNT}"
echo "    SHA-256: ${ZIP_SHA}"
echo "    Path:    ${EXPECTED_ZIP}"
