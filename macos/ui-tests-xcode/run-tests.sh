#!/usr/bin/env bash
# UI-test harness — runs the XCUITest suite locally on whatever machine
# this script is invoked on. Designed to be called either directly (when
# you're already on the VM) or via vm-test.sh from the host.
#
# What it does:
#   1. Regenerates the Xcode project from project.yml via xcodegen.
#   2. Manufactures any missing test fixtures deterministically (idempotent).
#   3. Sets the TEST_RUNNER_NPP_HEXEDIT_FIXTURES_DIR env var so the test
#      bundle finds them at runtime (xcodebuild only forwards env vars
#      prefixed with TEST_RUNNER_; the prefix is stripped before delivery).
#   4. Invokes xcodebuild test, forwarding any extra args verbatim so a
#      caller can pass -only-testing:<...> filters.
#   5. Writes test-results.md (machine-readable summary) and copies any
#      captureToDashboard PNGs into build/screenshots.
#
# Usage:
#   run-tests.sh                                  # routine suite
#                                                 # (excludes HexEditorLargeFileUITests)
#   run-tests.sh --large-files                    # include multi-GB tests
#                                                 # (also generates the 1.5 GB fixture)
#   run-tests.sh -only-testing:HexEditorUITests/HexEditorUITests/testFoo
#                                                # filter to a single test
#   run-tests.sh -only-testing:HexEditorUITests/HexEditorUITests/testFoo \
#                -only-testing:HexEditorUITests/HexEditorUITests/testBar
#                                                # filter to multiple
#   run-tests.sh -h | --help                     # this message
#
# Test classes:
#   HexEditorUITests/HexEditorUITests             # routine UI tests (default)
#   HexEditorUITests/HexEditorLargeFileUITests    # multi-GB tests, opt-in via --large-files
#
# All non-flag args are forwarded to xcodebuild (typically -only-testing:
# selectors). Test names follow the pattern
# HexEditorUITests/<className>/<methodName>.
#
# Outputs (relative to this script's directory):
#   build/test-results.md           machine-readable per-test summary
#   build/HexEditorUITests.xcresult Xcode result bundle (full detail)
#   build/screenshots/              PNGs from captureToDashboard helpers
#
# Most users invoke this indirectly via macos/scripts/test-ui.sh, which
# adds the host→VM ssh-rsync layer. Calling run-tests.sh directly is
# useful when you're already on the VM (or running on host hardware).

set -euo pipefail

# Argument parsing — sieve our own flags out of $@ before forwarding
# the remainder to xcodebuild. Currently --large-files is the only
# script-owned flag.
INCLUDE_LARGE_FILES=0
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --large-files)
            INCLUDE_LARGE_FILES=1
            shift
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. Run: brew install xcodegen" >&2
    exit 2
fi

xcodegen generate >/dev/null

# Manufacture the 100 MB test fixture in-place if missing. The smaller fixtures
# are checked into the repo at fixtures/; 100MB.bin is too large for git so we
# generate it deterministically (each byte at offset N has value N mod 256).
# Generation is idempotent — re-runs are a no-op once the file exists, so the
# ~1-second cost is paid only on a fresh checkout / VM bootstrap.
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
mkdir -p "$FIXTURES_DIR"

# Generate a deterministic fixture file of `size` bytes at `path` if missing
# (or wrong size). Each byte cycles 0x20..0x7E (printable ASCII) — mirrors
# macos/scripts/generate-test-fixture.py so the on-disk pattern matches the
# checked-in smaller fixtures. Stays valid UTF-8 + free of \r/\n so
# Nextpad++ loads the file byte-for-byte without re-encoding or
# line-ending conversion. Idempotent: re-runs are a no-op once the file
# exists, so the cost is paid only on a fresh checkout / VM bootstrap.
ensure_fixture() {
    local path=$1 size=$2
    if [[ ! -f "$path" ]] || [[ "$(/usr/bin/stat -f%z "$path")" -ne "$size" ]]; then
        echo "==> Generating $path ($size bytes)"
        /usr/bin/python3 - "$path" "$size" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
chunk = bytes(range(0x20, 0x7F))  # 95 chars: space through tilde
period = len(chunk)
with open(path, "wb") as f:
    written = 0
    while written < size:
        remaining = size - written
        if remaining >= period:
            f.write(chunk); written += period
        else:
            f.write(chunk[:remaining]); written += remaining
PY
    fi
}

# 100 MB — too large for git, generated on first run (~1 s).
ensure_fixture "$FIXTURES_DIR/100MB.bin" $((100 * 1024 * 1024))

# 300 MB — exercises hex→hex paste ROUND-TRIP across the pbs IPC
# threshold on every routine commit. pbs silently drops public.data
# payloads somewhere in the multi-100-MB range; 300 MB is comfortably
# above where the bug manifests so the in-process snapshot
# short-circuit (introduced 2026-05-05) is the only path that can pass
# this test. Without it, the destination paste would fall through to
# the placeholder text and the test would fail. Costs ~3 s to generate
# (idempotent) and ~60 s to run.
ensure_fixture "$FIXTURES_DIR/300MB.bin" $((300 * 1024 * 1024))

# 17 MB — just past the 16 MB hex-text rendering cap in HexClipboardOwner.
# Used by the "above-cap shows placeholder" test to verify that an external
# text-paste consumer sees a human-readable sentence rather than a 51 MB
# string allocation. Smallest fixture that triggers the cap; keeps the
# end-to-end test runnable in ~30 s instead of the 100 MB fixture's 150 s.
ensure_fixture "$FIXTURES_DIR/17MB.bin" $((17 * 1024 * 1024))

# 1.5 GB (1_610_612_736 bytes) — large enough to exercise the lazy
# reader + promised-type owner against pbs IPC, the chunk-streamed
# clipboard paths, and the extra Scintilla pressure of an inserted
# multi-GB selection, while staying well clear of the 2³¹ INT_MAX
# off-by-ones in upstream Scintilla (LayoutLine sign-extends INT_MIN
# at exactly 2 GB, verified 2026-05-05 via diagnostic crash log). The
# 0.5 GB headroom under 2 GB also lets a separate test copy a 200 MB
# slice and paste at end-of-file without crossing INT_MAX. Used by
# HexEditorLargeFileUITests/testLargeFile_1_5GB_*.
#
# Generated only when --large-files is on the command line, because the
# fixture costs ~1.5 GB of disk plus ~12 s to generate and the tests
# themselves take a few minutes each (Cmd-C materializing the 1.5 GB
# selection into a contiguous snapshot + SCI_INSERTTEXT into the
# destination Scintilla on paste). The HexEditorLargeFileUITests class
# is `-skip-testing`'d below by default, so the fixture isn't needed
# for routine runs.
if [[ "$INCLUDE_LARGE_FILES" -eq 1 ]]; then
    ensure_fixture "$FIXTURES_DIR/1.5GB.bin" $((1536 * 1024 * 1024))
fi

# xcodebuild forwards env vars to the test process only when prefixed with
# TEST_RUNNER_ (the prefix is stripped before delivery). The Swift tests read
# NPP_HEXEDIT_FIXTURES_DIR to locate the fixture files at runtime.
export TEST_RUNNER_NPP_HEXEDIT_FIXTURES_DIR="$FIXTURES_DIR"

# Tests that call captureToDashboard(name) write PNG screenshots into their
# XCUITest runner's App Sandbox container (see helper docs in
# Tests/HexEditorUITests.swift for why arbitrary paths don't work). After the
# xcodebuild test pass completes, we sweep the container's
# captureToDashboard-screenshots/ directory and copy the PNGs into the public
# build/screenshots dir, where update-dashboard.py picks them up. Cleared at
# the start of each run so stale screenshots don't accumulate.
SCREENSHOT_DIR="$SCRIPT_DIR/build/screenshots"
rm -rf "$SCREENSHOT_DIR"
mkdir -p "$SCREENSHOT_DIR"

XCRESULT="build/HexEditorUITests.xcresult"
SUMMARY_MD="build/test-results.md"

rm -rf "$XCRESULT"

# By default, exclude the multi-GB tests from the routine UI suite — they
# need a fixture that's only generated when --large-files is on the
# command line, and a single test takes a few minutes (Cmd-C selection
# materialization + 1.5 GB Scintilla insert on paste). With
# --large-files, drop the skip so the class participates normally.
SKIP_LARGE_ARGS=()
if [[ "$INCLUDE_LARGE_FILES" -eq 0 ]]; then
    SKIP_LARGE_ARGS+=("-skip-testing:HexEditorUITests/HexEditorLargeFileUITests")
fi

# Run xcodebuild without aborting on failure so we can always emit the summary.
# The summary writer surfaces failure detail in a stable, machine-readable form
# at $SCRIPT_DIR/$SUMMARY_MD, so anyone running tests anywhere — host, Parallels
# VM, fresh git checkout — has the same actionable report at the same path.
set +e
xcodebuild \
    -project HexEditorUITests.xcodeproj \
    -scheme HexEditorUITests \
    -destination "platform=macOS" \
    -resultBundlePath "$XCRESULT" \
    test \
    ${SKIP_LARGE_ARGS[@]+"${SKIP_LARGE_ARGS[@]}"} \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
XCB_EXIT=$?
set -e

if [[ -d "$XCRESULT" ]]; then
    if /usr/bin/python3 "$SCRIPT_DIR/summarize-results.py" "$XCRESULT" "$SUMMARY_MD"; then
        echo ""
        echo "==> Summary written to $SCRIPT_DIR/$SUMMARY_MD"
    else
        echo "warning: summary writer failed; raw .xcresult at $SCRIPT_DIR/$XCRESULT" >&2
    fi
else
    echo "warning: no .xcresult bundle produced (build may have failed before tests ran)" >&2
fi

# Extract screenshots from the runner's App Sandbox container into the public
# screenshots dir. The runner ID looks like
# org.notepadplusplus.hexeditor.uitests.xctrunner; we glob across containers
# to be robust to renames. nullglob means the loop is a no-op when no test
# wrote any screenshots.
shopt -s nullglob
shot_count=0
for src_dir in "$HOME/Library/Containers/"*"/Data/captureToDashboard-screenshots"; do
    [[ -d "$src_dir" ]] || continue
    for png in "$src_dir"/*.png; do
        [[ -f "$png" ]] || continue
        cp "$png" "$SCREENSHOT_DIR/"
        shot_count=$((shot_count + 1))
    done
done
shopt -u nullglob
if [[ $shot_count -gt 0 ]]; then
    echo "==> Extracted $shot_count screenshot(s) → $SCREENSHOT_DIR"
fi

exit "$XCB_EXIT"
