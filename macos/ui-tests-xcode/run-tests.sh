#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. Run: brew install xcodegen" >&2
    exit 2
fi

xcodegen generate >/dev/null

rm -rf build/HexEditorUITests.xcresult

xcodebuild \
    -project HexEditorUITests.xcodeproj \
    -scheme HexEditorUITests \
    -destination "platform=macOS" \
    -resultBundlePath build/HexEditorUITests.xcresult \
    test \
    "$@"
