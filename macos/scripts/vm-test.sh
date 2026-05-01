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
#      test-code edits never reach the compiled test binary. Workaround:
#      rsync the entire ui-tests-xcode/ subtree to a VM-local working
#      directory (with --checksum so updates are detected by content, not
#      mtime) and run xcodebuild from there. The result bundle and Markdown
#      summary are copied back to the shared folder so the host can read them.
#
# Why we DO NOT wipe DerivedData: the test runner is ad-hoc signed, and its
# TCC (Privacy & Security → Accessibility) entry is keyed by the runner's
# code hash. Wiping DerivedData forces a fresh build → fresh hash → macOS
# treats it as a brand-new app and the user must re-grant Accessibility
# permission via System Settings before xcodebuild can drive automation. By
# preserving DerivedData, an unchanged source tree produces a byte-identical
# runner whose TCC grant survives. Pass --clean to force a wipe (use after a
# Swift toolchain upgrade or when something is genuinely stuck).
#
# First-run setup on a fresh VM: run vm-test-local.sh once with the VM's
# desktop visible so you can click "Allow" on the macOS Accessibility prompt
# that fires when the test runner first tries to drive Notepad++.app. Open
# System Settings → Privacy & Security → Accessibility and verify
# `HexEditorUITests-Runner` is listed and enabled. Subsequent runs are
# unattended.
#
# Usage:
#   ~/vm-test-local.sh                                              # full UI suite
#   ~/vm-test-local.sh -only-testing:HexEditorUITests/HexEditorUITests/<test-name>
#   ~/vm-test-local.sh --clean                                      # also wipe DerivedData
#
# Environment overrides (rarely needed — vm-bootstrap.sh writes a defaults
# file at ~/.npp-hexedit-vm.env that is sourced automatically):
#   NPP_HEXEDIT     path to NPP_HexEdit checkout (in shared folder)
#   NPP_MACOS       path to notepad-plus-plus-macos checkout
#   BUILD_DIR       VM-local CMake build directory
#   LOCAL_TESTS     VM-local mirror of the test sources

set -euo pipefail

WIPE_DERIVED=0
TEST_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--clean" ]]; then
        WIPE_DERIVED=1
    else
        TEST_ARGS+=("$arg")
    fi
done

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
# --exclude='fixtures/100MB.bin': the 100 MB UI test fixture is generated
# in-place on the VM by run-tests.sh; without the exclude, --delete would
# wipe it whenever the host doesn't have a matching file locally.
rsync -a --delete --checksum \
    --exclude=build \
    --exclude='*.xcodeproj' \
    --exclude='fixtures/100MB.bin' \
    "$NPP_HEXEDIT/macos/ui-tests-xcode/" \
    "$LOCAL_TESTS/"

DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [[ $WIPE_DERIVED -eq 1 ]]; then
    # Opt-in only (--clean). Default is to preserve DerivedData so the runner's
    # ad-hoc code hash stays stable and TCC keeps its Accessibility grant.
    echo "==> Wiping Xcode DerivedData for HexEditorUITests (--clean requested)"
    echo "    NOTE: you'll need to re-grant the runner's Accessibility permission"
    echo "          on the VM's System Settings → Privacy & Security → Accessibility"
    echo "    target: $DERIVED/HexEditorUITests-*"
    for d in "$DERIVED"/HexEditorUITests-*; do
        if [[ -d "$d" ]]; then
            echo "    removing: $d"
            rm -rf "$d"
        fi
    done
fi

echo "==> Launching XCUITest from $LOCAL_TESTS"
# xcodebuild forwards env vars to the test process only when they're prefixed
# with TEST_RUNNER_ (the prefix is stripped before delivery). Without this,
# NPP_MACOS_APP would be set in xcodebuild's own env but invisible to the
# Swift tests, and every UI test would skip with "Set NPP_MACOS_APP=...".
export TEST_RUNNER_NPP_MACOS_APP="$NPP_APP"
TEST_EXIT=0
# Bash 3.2 (and 5+ with `set -u`) treats `"${empty[@]}"` as referencing an
# unset variable. The `${var+...}` idiom expands to nothing when the array
# is unset/empty and to the quoted expansion when it has elements.
"$LOCAL_TESTS/run-tests.sh" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} || TEST_EXIT=$?

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
