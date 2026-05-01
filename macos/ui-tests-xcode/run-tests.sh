#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. Run: brew install xcodegen" >&2
    exit 2
fi

xcodegen generate >/dev/null

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

exit "$XCB_EXIT"
