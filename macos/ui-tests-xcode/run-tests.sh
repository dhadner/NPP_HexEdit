#!/usr/bin/env bash
set -euo pipefail

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
HUGE_FIXTURE="$FIXTURES_DIR/100MB.bin"
HUGE_SIZE=$((100 * 1024 * 1024))
if [[ ! -f "$HUGE_FIXTURE" ]] || [[ "$(/usr/bin/stat -f%z "$HUGE_FIXTURE")" -ne "$HUGE_SIZE" ]]; then
    echo "==> Generating $HUGE_FIXTURE ($HUGE_SIZE bytes)"
    /usr/bin/python3 - "$HUGE_FIXTURE" "$HUGE_SIZE" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
# Cycling 0x20..0x7E (printable ASCII). Mirrors macos/scripts/generate-test-fixture.py
# so the in-place 100MB fixture matches the checked-in smaller fixtures'
# pattern exactly. Stays valid UTF-8 + free of \r/\n so Notepad++ macOS
# loads the file byte-for-byte without re-encoding or line-ending conversion.
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
    "$@"
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
