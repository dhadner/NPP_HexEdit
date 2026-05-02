#!/usr/bin/env bash
# Run the XCUITest UI suite on the VM, consuming a host-pushed VM-local mirror.
#
# Invariant: this script READS NOTHING from /Volumes/My Shared Files/. The host
# wrapper (test-ui.sh) ssh-rsyncs the source tree and Notepad++.app into
# ~/vm-local/ first; this script consumes that mirror exclusively. That sidesteps
# Parallels' shared-folder read caching, which has historically served stale
# bytes after host edits.
#
# Self-healing guards (run at startup):
#   1. Verify ~/vm-local/NPP_HexEdit/macos/CMakeLists.txt exists. If not,
#      tell the user to run test-ui.sh from the host (which performs the
#      rsync).
#   2. If cmake isn't on PATH, source brew shellenv (Homebrew installs into
#      /opt/homebrew on Apple Silicon and a non-login ssh session won't
#      pick that up automatically).
#   3. If the CMake build directory's cached source path doesn't match
#      VM_HEXEDIT (e.g. the source path moved), wipe and reconfigure.
#
# Usage (normally invoked by test-ui.sh, but runnable directly on the VM
# after `test-ui.sh --list` has populated ~/vm-local):
#   ~/vm-local/NPP_HexEdit/macos/scripts/vm-test.sh
#   ~/vm-local/NPP_HexEdit/macos/scripts/vm-test.sh -only-testing:...
#   ~/vm-local/NPP_HexEdit/macos/scripts/vm-test.sh --clean      # wipe DerivedData
#   ~/vm-local/NPP_HexEdit/macos/scripts/vm-test.sh --list       # enumerate; do not run
#
# DerivedData is preserved by default. The runner's TCC Accessibility grant
# is keyed by its ad-hoc-signed code hash; wiping DerivedData forces a fresh
# hash and the user must re-grant Accessibility before the next run.

set -euo pipefail

WIPE_DERIVED=0
LIST_ONLY=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean) WIPE_DERIVED=1 ;;
        --list)  LIST_ONLY=1 ;;
        *)       TEST_ARGS+=("$arg") ;;
    esac
done

# ---- Paths (constants — no env file needed) -------------------------------

VM_HEXEDIT="$HOME/vm-local/NPP_HexEdit"
VM_NPP_MACOS="$HOME/vm-local/notepad-plus-plus-macos"
VM_APP="$HOME/vm-local/Notepad++.app"
BUILD_DIR="$HOME/build-NPP_HexEdit"

# ---- Self-healing guard 1: VM-local mirror exists -------------------------

if [[ ! -f "$VM_HEXEDIT/macos/CMakeLists.txt" ]]; then
    echo "error: $VM_HEXEDIT/macos/CMakeLists.txt missing" >&2
    echo "       Run test-ui.sh from the host first — it ssh-rsyncs the source here." >&2
    exit 2
fi
if [[ ! -f "$VM_NPP_MACOS/src/NppPluginInterfaceMac.h" ]]; then
    echo "error: $VM_NPP_MACOS/src/NppPluginInterfaceMac.h missing" >&2
    echo "       Run test-ui.sh from the host first — it ssh-rsyncs the NPP macOS headers here." >&2
    exit 2
fi
if [[ ! -d "$VM_APP" ]]; then
    echo "error: $VM_APP missing" >&2
    echo "       Run test-ui.sh from the host first — it ssh-rsyncs Notepad++.app here." >&2
    exit 2
fi

# ---- Self-healing guard 2: cmake on PATH ----------------------------------

if ! command -v cmake >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake not on PATH; install via Homebrew or invoke under bash -lc" >&2
    exit 2
fi

# ---- --list short-circuit -------------------------------------------------

if [[ $LIST_ONLY -eq 1 ]]; then
    grep -E '^\s+func test[A-Z][A-Za-z0-9_]+' \
         "$VM_HEXEDIT/macos/ui-tests-xcode/Tests/HexEditorUITests.swift" \
        | sed -E 's/.*func (test[A-Za-z0-9_]+).*/\1/' \
        | sort -u
    exit 0
fi

# ---- Self-healing guard 3: CMake cache matches source path ----------------

CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
MAKEFILE="$BUILD_DIR/Makefile"
NEED_CONFIGURE=0
if [[ ! -f "$CACHE_FILE" || ! -f "$MAKEFILE" ]]; then
    # Either fresh dir or a previous configure failed mid-flight (cache written
    # but Makefile generation aborted). Either way, start clean.
    NEED_CONFIGURE=1
    rm -rf "$BUILD_DIR"
elif ! grep -qF "CMAKE_HOME_DIRECTORY:INTERNAL=$VM_HEXEDIT/macos" "$CACHE_FILE"; then
    cached_src=$(awk -F= '/^CMAKE_HOME_DIRECTORY:/ {print $2}' "$CACHE_FILE" | head -1)
    echo "==> CMake cache source ($cached_src) differs from current; reconfiguring"
    NEED_CONFIGURE=1
    rm -rf "$BUILD_DIR"
fi
if [[ $NEED_CONFIGURE -eq 1 ]]; then
    echo "==> Configuring CMake build"
    cmake -S "$VM_HEXEDIT/macos" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DNPP_MACOS_DIR="$VM_NPP_MACOS" >/dev/null
fi

# ---- Build + install plugin ----------------------------------------------

echo "==> Rebuilding plugin (incremental)"
cmake --build "$BUILD_DIR"

echo "==> Reinstalling to ~/.notepad++/plugins/HexEditor/"
cmake --install "$BUILD_DIR" >/dev/null

DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [[ $WIPE_DERIVED -eq 1 ]]; then
    echo "==> Wiping Xcode DerivedData for HexEditorUITests (--clean requested)"
    echo "    NOTE: re-grant Accessibility in System Settings → Privacy & Security"
    for d in "$DERIVED"/HexEditorUITests-*; do
        if [[ -d "$d" ]]; then
            echo "    removing: $d"
            rm -rf "$d"
        fi
    done
fi

# ---- Run tests via the existing run-tests.sh harness ---------------------

LOCAL_TESTS="$VM_HEXEDIT/macos/ui-tests-xcode"

echo "==> Launching XCUITest from $LOCAL_TESTS"
# xcodebuild only forwards env vars prefixed with TEST_RUNNER_ (prefix stripped
# before delivery). Without this, the Swift tests would skip with
# "Set NPP_MACOS_APP=...".
export TEST_RUNNER_NPP_MACOS_APP="$VM_APP"
TEST_EXIT=0
"$LOCAL_TESTS/run-tests.sh" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} || TEST_EXIT=$?

# ---- Update dashboard (best-effort, never masks the test exit) -----------

DASHBOARD_HELPER="$LOCAL_TESTS/update-dashboard.py"
SHARED_BUILD="$LOCAL_TESTS/build"
if [[ -f "$DASHBOARD_HELPER" ]]; then
    if /usr/bin/python3 "$DASHBOARD_HELPER" \
        --xcresult "$LOCAL_TESTS/build/HexEditorUITests.xcresult" \
        --tests-source "$LOCAL_TESTS/Tests/HexEditorUITests.swift" \
        --history "$SHARED_BUILD/run-history.json" \
        --md "$SHARED_BUILD/dashboard.md" \
        --html "$SHARED_BUILD/dashboard.html" \
        --screenshots-dir "$SHARED_BUILD/screenshots" 2>&1; then
        echo "==> Dashboard updated: $SHARED_BUILD/dashboard.html"
    fi
fi

exit "$TEST_EXIT"
