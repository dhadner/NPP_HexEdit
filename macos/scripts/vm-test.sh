#!/usr/bin/env bash
# Run the XCUITest UI suite (or a subset) inside the Parallels VM.
#
# Parallels' shared-folder driver has aggressive SMB-style caching that bites
# us in two specific places:
#   1. bash reads vm-test.sh with stale content even when sed/grep/cp see the
#      latest version. Workaround: invoke this script from a VM-local copy:
#        cp "$NPP_HEXEDIT/macos/scripts/vm-test.sh" ~/vm-test-local.sh
#        chmod +x ~/vm-test-local.sh
#        ~/vm-test-local.sh ...
#      Re-copy after any edits I push to the shared script.
#   2. swiftc compiles .swift sources from the share with stale content, so
#      test-code edits never reach the compiled test binary even after a
#      DerivedData wipe. Workaround: rsync the entire ui-tests-xcode/ subtree
#      to a VM-local working directory, run xcodebuild from there. The result
#      bundle and Markdown summary are copied back to the shared folder so
#      the host can read them.
#
# Usage:
#   ~/vm-test-local.sh                                              # full UI suite
#   ~/vm-test-local.sh -only-testing:HexEditorUITests/HexEditorUITests/<test-name>
#
# Environment overrides (rarely needed — vm-bootstrap.sh writes a defaults
# file at ~/.npp-hexedit-vm.env that is sourced automatically):
#   NPP_HEXEDIT     path to NPP_HexEdit checkout (in shared folder)
#   NPP_MACOS       path to notepad-plus-plus-macos checkout
#   BUILD_DIR       VM-local CMake build directory
#   LOCAL_TESTS     VM-local mirror of the test sources

set -euo pipefail

if [[ -f "$HOME/.npp-hexedit-vm.env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.npp-hexedit-vm.env"
fi

: "${NPP_HEXEDIT:?Set NPP_HEXEDIT or run vm-bootstrap.sh first.}"
: "${NPP_MACOS:?Set NPP_MACOS or run vm-bootstrap.sh first.}"
: "${BUILD_DIR:=$HOME/build-NPP_HexEdit}"
: "${LOCAL_TESTS:=$HOME/ui-tests-local}"

NPP_APP="$NPP_MACOS/build/Notepad++.app"
[[ -d "$NPP_APP" ]] || {
    echo "error: Notepad++.app not found at $NPP_APP" >&2
    echo "       Build it on the host (or inside the VM) before running UI tests." >&2
    exit 2
}

echo "==> Rebuilding plugin (incremental)"
cmake --build "$BUILD_DIR"

echo "==> Reinstalling to ~/.notepad++/plugins/HexEditor/"
cmake --install "$BUILD_DIR" >/dev/null

# Mirror the test source from shared folder to VM-local FS. swiftc reading
# .swift sources directly from the share gets stale cached content — even cp
# right after a host edit can serve old bytes — so we use rsync, which uses
# checksum-based detection rather than mtime to ensure the mirror reflects
# the host's current state.
echo "==> Syncing test source from shared folder to $LOCAL_TESTS"
mkdir -p "$LOCAL_TESTS"
rsync -a --delete --checksum \
    --exclude=build \
    --exclude='*.xcodeproj' \
    "$NPP_HEXEDIT/macos/ui-tests-xcode/" \
    "$LOCAL_TESTS/"

# Wipe Xcode's DerivedData so nothing carries over from a previous run that
# may have cached a stale source file. The local mirror above means the next
# xcodebuild compiles from fresh content.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
echo "==> Wiping Xcode DerivedData for HexEditorUITests"
echo "    target: $DERIVED/HexEditorUITests-*"
for d in "$DERIVED"/HexEditorUITests-*; do
    if [[ -d "$d" ]]; then
        echo "    removing: $d"
        rm -rf "$d"
    fi
done

echo "==> Launching XCUITest from $LOCAL_TESTS"
export NPP_MACOS_APP="$NPP_APP"
TEST_EXIT=0
"$LOCAL_TESTS/run-tests.sh" "$@" || TEST_EXIT=$?

# Copy the result bundle and the human-readable summary back to the shared
# folder so the host (and any code that reads via the share) can see them at
# the canonical path.
SHARED_BUILD="$NPP_HEXEDIT/macos/ui-tests-xcode/build"
mkdir -p "$SHARED_BUILD"
if [[ -f "$LOCAL_TESTS/build/test-results.md" ]]; then
    cp "$LOCAL_TESTS/build/test-results.md" "$SHARED_BUILD/test-results.md"
    echo "==> Copied test-results.md back to $SHARED_BUILD/"
fi
if [[ -d "$LOCAL_TESTS/build/HexEditorUITests.xcresult" ]]; then
    rm -rf "$SHARED_BUILD/HexEditorUITests.xcresult"
    cp -R "$LOCAL_TESTS/build/HexEditorUITests.xcresult" \
        "$SHARED_BUILD/HexEditorUITests.xcresult"
    echo "==> Copied HexEditorUITests.xcresult back to $SHARED_BUILD/"
fi

exit "$TEST_EXIT"
