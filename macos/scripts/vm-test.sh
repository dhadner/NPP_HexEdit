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
#   ~/vm-local/NPP_HexEdit/macos/scripts/vm-test.sh --asan       # build + load ASan-instrumented plugin
#
# DerivedData is preserved by default. The runner's TCC Accessibility grant
# is keyed by its ad-hoc-signed code hash; wiping DerivedData forces a fresh
# hash and the user must re-grant Accessibility before the next run.
#
# --asan: build the plugin with -fsanitize=address,undefined and install the
# instrumented dylib instead of the regular one. Any heap overrun /
# use-after-free / signed-overflow inside our code path triggers a sanitizer
# abort that fails the test. Uses a separate build dir
# (~/build-NPP_HexEdit-asan) so the regular and instrumented builds don't
# stomp each other's CMake caches.
#
# Critical wiring detail: a dlopen-loaded ASan-instrumented dylib aborts the
# host with "Interceptors are not working" because ASan's runtime self-test
# fails when dyld brings up the plugin after the host's first malloc. The
# fix is to inject ASan into NPP at process launch via DYLD_INSERT_LIBRARIES
# (the env var is set in the XCUITest helper's launchEnvironment so XCUI's
# launch-services path forwards it). NPP-Mac is ad-hoc signed with no
# entitlements, so SIP doesn't strip the variable. Runtime overhead measured
# at ~15% on the Parallels VM (UI suite grows from ~46 min to ~53 min).

set -euo pipefail

WIPE_DERIVED=0
LIST_ONLY=0
ASAN_BUILD=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean) WIPE_DERIVED=1 ;;
        --list)  LIST_ONLY=1 ;;
        --asan)  ASAN_BUILD=1 ;;
        *)       TEST_ARGS+=("$arg") ;;
    esac
done

# ---- Paths (constants — no env file needed) -------------------------------

VM_HEXEDIT="$HOME/vm-local/NPP_HexEdit"
VM_NPP_MACOS="$HOME/vm-local/notepad-plus-plus-macos"
VM_APP="$HOME/vm-local/Notepad++.app"
if [[ $ASAN_BUILD -eq 1 ]]; then
    BUILD_DIR="$HOME/build-NPP_HexEdit-asan"
else
    BUILD_DIR="$HOME/build-NPP_HexEdit"
fi

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

# ---- Self-healing guard 4: code-signing identity present ------------------
#
# project.yml's CODE_SIGN_IDENTITY references a self-signed cert that each
# developer installs locally into a dedicated, always-unlocked keychain.
# (Login keychain doesn't work — it's locked from this SSH session's
# launchd domain perspective and codesign returns errSecInternalComponent.)
# Without the cert, xcodebuild fails the test bundle's CodeSign phase
# ~30 s into a run. Detect early and point at the install script.

CERT_NAME="NPP-HexEdit Test Codesign"
CODESIGN_KEYCHAIN="$HOME/Library/Keychains/NPP-HexEdit-Codesign.keychain-db"
# Hardcoded password matches install-test-codesign-cert.sh; the keychain
# only holds a self-signed local-test cert so leaking the password leaks
# nothing useful.
CODESIGN_KEYCHAIN_PASS="npp-hexedit-test"
if [[ ! -f "$CODESIGN_KEYCHAIN" ]] || \
   ! security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN" 2>/dev/null \
        | grep -q -F "$CERT_NAME"; then
    echo "error: code-signing identity '$CERT_NAME' not found in dedicated keychain." >&2
    echo "       Run: bash $VM_HEXEDIT/macos/scripts/install-test-codesign-cert.sh" >&2
    echo "       (Run it directly in the VM's Terminal — the trust step needs GUI auth," >&2
    echo "        which an SSH session can't supply.)" >&2
    exit 2
fi

# Unlock the dedicated keychain for this SSH session. Keychain unlock state
# is per launchd domain on macOS — the unlock done in the GUI install
# script doesn't propagate to the SSH session that vm-test.sh runs under,
# so codesign would fail with errSecInternalComponent ("can't access private
# key") even though the cert is visible. unlock-keychain is fast (~100 ms)
# and idempotent, so we just do it on every run.
if ! security unlock-keychain -p "$CODESIGN_KEYCHAIN_PASS" "$CODESIGN_KEYCHAIN" 2>/dev/null; then
    echo "error: failed to unlock $CODESIGN_KEYCHAIN — was the install script run with the expected password?" >&2
    exit 2
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
    if [[ $ASAN_BUILD -eq 1 ]]; then
        echo "==> Configuring CMake build (ASan + UBSan, Debug)"
        cmake -S "$VM_HEXEDIT/macos" -B "$BUILD_DIR" \
            -DCMAKE_BUILD_TYPE=Debug \
            -DENABLE_SANITIZERS=ON \
            -DNPP_MACOS_DIR="$VM_NPP_MACOS" >/dev/null
    else
        echo "==> Configuring CMake build"
        cmake -S "$VM_HEXEDIT/macos" -B "$BUILD_DIR" \
            -DCMAKE_BUILD_TYPE=Release \
            -DNPP_MACOS_DIR="$VM_NPP_MACOS" >/dev/null
    fi
fi

# ---- Build + install plugin ----------------------------------------------

if [[ $ASAN_BUILD -eq 1 ]]; then
    echo "==> Rebuilding plugin (incremental, ASan-instrumented)"
else
    echo "==> Rebuilding plugin (incremental)"
fi
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
if [[ $ASAN_BUILD -eq 1 ]]; then
    # Tell the Swift test harness to scale long-poll timeouts; menu construction
    # is somewhat slower with ASan inserted into NPP itself, though far less
    # dramatic than feared (~2× rather than 10×).
    export TEST_RUNNER_NPP_HEXEDIT_ASAN=1
    # ASan-runtime tuning forwarded to NPP via the helper's launchEnvironment:
    # - malloc_context_size=0 — drop per-allocation stack traces; NPP makes
    #   many small allocations during AppKit interaction and recording each
    #   stack dominates runtime overhead.
    # - quarantine_size_mb=4 — keep some use-after-free detection but cap
    #   memory pressure (default 256 MiB stresses the VM).
    # - detect_leaks=0 — LSan-on-exit isn't useful here and slows shutdown.
    # - abort_on_error=1 — fail loud, don't continue past the first report.
    export TEST_RUNNER_NPP_HEXEDIT_ASAN_OPTIONS="malloc_context_size=0:quarantine_size_mb=4:detect_leaks=0:abort_on_error=1"

    # Critical: the ASan-instrumented plugin can't be loaded into a non-ASan
    # host via dlopen. ASan's own self-test fails with
    #   "Interceptors are not working. ... Please launch the executable with:
    #    DYLD_INSERT_LIBRARIES=.../libclang_rt.asan_osx_dynamic.dylib"
    # because NPP's mallocs already happened by the time dyld brings up our
    # dylib. We force ASan into NPP at process launch via DYLD_INSERT_LIBRARIES.
    # NPP-Mac is ad-hoc signed with no entitlements, so SIP doesn't strip the
    # var. Resolve the dylib at run time so we don't bake a Xcode version
    # number into the script.
    ASAN_DYLIB=$(clang -print-file-name=libclang_rt.asan_osx_dynamic.dylib 2>/dev/null)
    if [[ ! -f "$ASAN_DYLIB" ]]; then
        echo "error: couldn't resolve libclang_rt.asan_osx_dynamic.dylib via clang -print-file-name; ASan UI tier requires it." >&2
        exit 2
    fi
    echo "==> ASan runtime: $ASAN_DYLIB"
    export TEST_RUNNER_NPP_HEXEDIT_ASAN_DYLIB="$ASAN_DYLIB"
fi
TEST_EXIT=0
"$LOCAL_TESTS/run-tests.sh" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} || TEST_EXIT=$?

# ---- Update dashboard (best-effort, never masks the test exit) -----------
#
# Tag the run as "full" or "partial" based on whether any -only-testing:
# args were passed. The dashboard's headline is the latest *full* run so a
# subsequent debug subset run (testFoo passed in 5s) doesn't paper over an
# earlier full-suite failure.

RUN_KIND="full"
for arg in ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}; do
    if [[ "$arg" == -only-testing:* ]]; then
        RUN_KIND="partial"
        break
    fi
done

DASHBOARD_HELPER="$LOCAL_TESTS/update-dashboard.py"
SHARED_BUILD="$LOCAL_TESTS/build"
if [[ -f "$DASHBOARD_HELPER" ]]; then
    if /usr/bin/python3 "$DASHBOARD_HELPER" \
        --xcresult "$LOCAL_TESTS/build/HexEditorUITests.xcresult" \
        --tests-source "$LOCAL_TESTS/Tests/HexEditorUITests.swift" \
        --history "$SHARED_BUILD/run-history.json" \
        --md "$SHARED_BUILD/dashboard.md" \
        --html "$SHARED_BUILD/dashboard.html" \
        --kind "$RUN_KIND" \
        --screenshots-dir "$SHARED_BUILD/screenshots" 2>&1; then
        echo "==> Dashboard updated: $SHARED_BUILD/dashboard.html"
    fi
fi

exit "$TEST_EXIT"
