#!/usr/bin/env bash
# One-command UI test runner — runs the XCUITest suite on the Parallels VM.
#
# This is the host-side entry point. It:
#   1. SSH-rsyncs the NPP_HexEdit source tree and Notepad++.app from the
#      host's actual filesystem to a VM-local mirror at ~/vm-local/.
#   2. SSH-invokes the VM-local copy of vm-test.sh, which reads only from
#      that mirror — never from the Parallels shared folder.
#
# Why the redesign: Parallels' shared-folder driver caches reads
# aggressively, so any read of a freshly-edited file through the share may
# return stale bytes. ssh-rsync from the host's filesystem to the VM
# bypasses the share entirely. ~1s cold per run, <1s warm — verified.
#
# Required: SSH alias `npp-vm` must be configured (see DEVELOPER.md, "VM SSH").
#
# Usage:
#   test-ui.sh                          # run the routine UI suite
#   test-ui.sh testFoo testBar          # run a subset by name
#   test-ui.sh --list                   # enumerate test names; do not run
#   test-ui.sh --failed                 # re-run last run's failures
#   test-ui.sh --clean                  # forward --clean to vm-test.sh (wipe DerivedData)
#   test-ui.sh --asan                   # build + load ASan-instrumented plugin (slower run, catches plugin-side memory bugs)
#   test-ui.sh --large-files            # include the multi-GB tests (HexEditorLargeFileUITests class)
#                                       # generates the 1.5 GB fixture; adds a few min per included test
#   test-ui.sh --re-bootstrap           # re-run vm-bootstrap.sh on the VM
#   test-ui.sh --dashboard              # open the latest dashboard.html in browser
#   test-ui.sh -h | --help              # this message
#
# Test classes (filterable via -only-testing forwarded args):
#   HexEditorUITests/HexEditorUITests             # routine suite (default)
#   HexEditorUITests/HexEditorLargeFileUITests    # multi-GB tests (opt-in via --large-files)
#
# Test names match the function names in HexEditorUITests.swift. The full
# -only-testing prefix (HexEditorUITests/HexEditorUITests/...) is added
# automatically when you pass a bare name.
#
# --asan: builds the plugin under -fsanitize=address,undefined and installs
# the instrumented dylib. The ASan runtime is force-loaded into NPP at
# process launch via DYLD_INSERT_LIBRARIES (set in the XCUITest helper's
# launchEnvironment) — see vm-test.sh for the rationale. Any heap overrun /
# use-after-free / signed-overflow inside our plugin's runtime path aborts
# with an ASan stack trace and fails the test. UI suite measured at ~25 min
# under ASan vs. ~22 min baseline. Use this as a periodic gate — the
# unit-tier tests catch buffer-shape bugs at < 1 ms feedback; the ASan UI
# run is the broader net for runtime-only paths the unit suite doesn't
# reach.

set -euo pipefail

VM_HOST="npp-vm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEXEDIT_SRC="$REPO_ROOT"
NPP_MACOS_SRC="$(cd "$REPO_ROOT/../notepad-plus-plus-macos" && pwd)"
NPP_APP_SRC="$NPP_MACOS_SRC/build/Notepad++.app"

VM_HEXEDIT="\$HOME/vm-local/NPP_HexEdit"            # remote path (escaped for ssh)
VM_NPP_MACOS="\$HOME/vm-local/notepad-plus-plus-macos"
VM_APP="\$HOME/vm-local/Notepad++.app"

DASHBOARD_HTML="$REPO_ROOT/macos/ui-tests-xcode/build/dashboard.html"
DASHBOARD_MD="$REPO_ROOT/macos/ui-tests-xcode/build/dashboard.md"
SUMMARY_MD="$REPO_ROOT/macos/ui-tests-xcode/build/test-results.md"

cyan()   { printf '\033[1;36m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

usage() {
    sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
    # ^ keep range in sync with the comment-block boundary above (last line: "automatically when you pass a bare name.").
    exit 0
}

# ---- Argument parsing ------------------------------------------------------

DO_LIST=0
DO_FAILED=0
DO_REBOOTSTRAP=0
DO_DASHBOARD=0
WIPE_DERIVED=0
ASAN_BUILD=0
INCLUDE_LARGE_FILES=0
TEST_NAMES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)         usage ;;
        --list)            DO_LIST=1 ;;
        --failed)          DO_FAILED=1 ;;
        --re-bootstrap)    DO_REBOOTSTRAP=1 ;;
        --dashboard)       DO_DASHBOARD=1 ;;
        --clean)           WIPE_DERIVED=1 ;;
        --asan)            ASAN_BUILD=1 ;;
        --large-files)     INCLUDE_LARGE_FILES=1 ;;
        --)                shift; TEST_NAMES+=("$@"); break ;;
        -*)
            red "unknown flag: $1"
            red "see: test-ui.sh --help"
            exit 2
            ;;
        *)                 TEST_NAMES+=("$1") ;;
    esac
    shift
done

# --dashboard short-circuit: just open the file, no VM round trip.
if [[ $DO_DASHBOARD -eq 1 ]]; then
    if [[ -f "$DASHBOARD_HTML" ]]; then
        cyan "Opening $DASHBOARD_HTML"
        open "$DASHBOARD_HTML"
    else
        red "no dashboard yet at $DASHBOARD_HTML — run a test first"
        exit 1
    fi
    exit 0
fi

# ---- Sanity checks on host -------------------------------------------------

if [[ ! -f "$HEXEDIT_SRC/macos/CMakeLists.txt" ]]; then
    red "host source tree malformed: $HEXEDIT_SRC/macos/CMakeLists.txt missing"
    exit 2
fi
if [[ ! -f "$NPP_MACOS_SRC/src/NppPluginInterfaceMac.h" ]]; then
    red "Notepad++ macOS source tree missing at $NPP_MACOS_SRC"
    red "Expected sibling checkout next to NPP_HexEdit/."
    exit 2
fi
if [[ ! -d "$NPP_APP_SRC" ]]; then
    red "Notepad++.app not found at $NPP_APP_SRC"
    red "Build it on the host first (see DEVELOPER.md), then re-run."
    exit 2
fi

# ---- VM reachability check -------------------------------------------------

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_HOST" 'true' 2>/dev/null; then
    red "Cannot reach VM at host alias '$VM_HOST'. Checks:"
    red "  1. Is the Parallels VM running?"
    red "  2. Is the SSH alias 'npp-vm' configured? (see ~/.ssh/config)"
    red "  3. Run manually:  ssh $VM_HOST true"
    exit 2
fi

# ---- --re-bootstrap path ---------------------------------------------------

if [[ $DO_REBOOTSTRAP -eq 1 ]]; then
    cyan "==> Re-bootstrapping VM (Homebrew, cmake, xcodegen, build dirs)"
    # Push the bootstrap script directly via rsync, then invoke it.
    ssh "$VM_HOST" 'mkdir -p ~/vm-local'
    rsync -a -e ssh "$SCRIPT_DIR/vm-bootstrap.sh" "$VM_HOST:vm-bootstrap-local.sh"
    ssh "$VM_HOST" 'chmod +x ~/vm-bootstrap-local.sh && bash -lc "~/vm-bootstrap-local.sh"'
    cyan "==> Bootstrap complete. Run: test-ui.sh"
    exit 0
fi

# ---- Mirror source tree + app to VM-local via ssh-rsync --------------------
#
# This is the bypass for Parallels shared-folder caching. Rsync over ssh
# reads from the host's actual filesystem — not the share — so the bytes
# delivered to the VM always reflect the latest host edits.

cyan "==> Mirroring source tree to VM:~/vm-local/NPP_HexEdit"
ssh "$VM_HOST" 'mkdir -p ~/vm-local/NPP_HexEdit ~/vm-local/Notepad++.app ~/vm-local/notepad-plus-plus-macos/src ~/vm-local/notepad-plus-plus-macos/scintilla/include'

# --checksum: don't trust mtime across the ssh hop. --delete: prune removed files.
# Excludes: build dirs (VM has its own), .git (large + unneeded), runner-local
# DerivedData inside the test bundle, and the 100MB fixture (regenerated in-place).
rsync -a --delete --checksum -e ssh \
    --exclude='.git' \
    --exclude='build' \
    --exclude='build-asan' \
    --exclude='build-fuzz' \
    --exclude='build-universal' \
    --exclude='__pycache__' \
    --exclude='ui-tests-xcode/build' \
    --exclude='ui-tests-xcode/HexEditorUITests.xcodeproj' \
    --exclude='ui-tests-xcode/fixtures/100MB.bin' \
    "$HEXEDIT_SRC/" \
    "$VM_HOST:vm-local/NPP_HexEdit/"

# Mirror only the two header subtrees CMake actually consumes — see
# macos/CMakeLists.txt:23-25 for the path layout. Pushing all of NPP macOS
# would be 200+ MB of build dirs and source we don't need.
cyan "==> Mirroring Notepad++ macOS headers (src/ + scintilla/include/)"
rsync -a --delete --checksum -e ssh \
    "$NPP_MACOS_SRC/src/" \
    "$VM_HOST:vm-local/notepad-plus-plus-macos/src/"
rsync -a --delete --checksum -e ssh \
    "$NPP_MACOS_SRC/scintilla/include/" \
    "$VM_HOST:vm-local/notepad-plus-plus-macos/scintilla/include/"

cyan "==> Mirroring Notepad++.app to VM:~/vm-local/Notepad++.app"
rsync -a --delete --checksum -e ssh \
    "$NPP_APP_SRC/" \
    "$VM_HOST:vm-local/Notepad++.app/"

# ---- --list short-circuit (no test run, just enumerate) -------------------

if [[ $DO_LIST -eq 1 ]]; then
    cyan "==> Enumerating UI tests"
    ssh "$VM_HOST" "bash -lc 'bash $VM_HEXEDIT/macos/scripts/vm-test.sh --list'"
    exit 0
fi

# ---- --failed: read last run's failures from local summary ----------------

if [[ $DO_FAILED -eq 1 ]]; then
    if [[ ! -f "$SUMMARY_MD" ]]; then
        red "no prior run found at $SUMMARY_MD — run all tests first"
        exit 1
    fi
    mapfile -t failed < <(grep -E '^### `' "$SUMMARY_MD" 2>/dev/null \
                          | sed -E 's/^### `([^`]+)`.*/\1/' \
                          | sed -E 's/^test_[A-Za-z]+_test_(test.*)/\1/' \
                          | sort -u)
    if [[ ${#failed[@]} -eq 0 ]]; then
        cyan "no failures in last run; nothing to re-run"
        exit 0
    fi
    cyan "==> Re-running ${#failed[@]} failed test(s)"
    for name in "${failed[@]}"; do
        cyan "    - $name"
        TEST_NAMES+=("$name")
    done
fi

# ---- Build the -only-testing args -----------------------------------------

ONLY_TESTING=()
for name in ${TEST_NAMES[@]+"${TEST_NAMES[@]}"}; do
    # Route by name prefix: testLargeFile_* → HexEditorLargeFileUITests,
    # everything else → HexEditorUITests. Keeps callers from having to
    # know which class a test lives in.
    if [[ "$name" == testLargeFile_* ]]; then
        ONLY_TESTING+=("-only-testing:HexEditorUITests/HexEditorLargeFileUITests/$name")
    else
        ONLY_TESTING+=("-only-testing:HexEditorUITests/HexEditorUITests/$name")
    fi
done

EXTRA_FLAGS=()
[[ $WIPE_DERIVED -eq 1 ]] && EXTRA_FLAGS+=("--clean")
[[ $ASAN_BUILD -eq 1 ]] && EXTRA_FLAGS+=("--asan")
[[ $INCLUDE_LARGE_FILES -eq 1 ]] && EXTRA_FLAGS+=("--large-files")

# ---- Run tests on VM ------------------------------------------------------

if [[ ${#ONLY_TESTING[@]} -eq 0 ]]; then
    cyan "==> Running ALL UI tests on $VM_HOST"
    yellow "    (XCUITest synthesizes events through Window Server; the VM's"
    yellow "     keyboard/mouse will be in use during the run)"
else
    cyan "==> Running ${#TEST_NAMES[@]} UI test(s) on $VM_HOST"
fi

# Build the remote command. Each arg goes through ssh's command line, so we
# rely on bash word splitting on the remote side (vm-test.sh's arg parser is
# tolerant of single-arg test filters). The `${var+expansion}` idiom is needed
# because `set -u` is on and "${arr[@]}" raises "unbound variable" when arr is
# an empty array.
remote_cmd="bash $VM_HEXEDIT/macos/scripts/vm-test.sh"
for f in ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}; do
    remote_cmd+=" $f"
done
for o in ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"}; do
    remote_cmd+=" '$o'"
done

TEST_EXIT=0
ssh "$VM_HOST" "bash -lc \"$remote_cmd\"" || TEST_EXIT=$?

# ---- Pull results back from VM (via ssh-rsync, not the share) -------------

cyan "==> Copying results back from VM"
SHARED_BUILD="$REPO_ROOT/macos/ui-tests-xcode/build"
mkdir -p "$SHARED_BUILD"
rsync -a --delete -e ssh \
    "$VM_HOST:vm-local/NPP_HexEdit/macos/ui-tests-xcode/build/" \
    "$SHARED_BUILD/" 2>/dev/null || true

# ---- Sync host plugin to match the version we just tested ------------------
#
# Without this step, the host's Notepad++ keeps loading whichever HexEditor.dylib
# was last installed on the host. After a host source edit, the VM gets the new
# code (via ssh-rsync) but the host plugin stays stale until manually rebuilt.
# Rebuild + install on the host so that what the user sees in their own
# Notepad++ matches what the VM just tested. ~3-5s on an incremental build.
HOST_BUILD_DIR="$REPO_ROOT/macos/build"
if [[ $ASAN_BUILD -eq 1 ]]; then
    # Skip host install for ASan runs — we don't want to replace the user's
    # day-to-day plugin with the 2× slower instrumented build. ASan runs are
    # CI-style verification only; the regular host plugin is left alone.
    yellow "==> Skipping host plugin sync (--asan run; user's regular plugin preserved)"
elif [[ -f "$HOST_BUILD_DIR/CMakeCache.txt" ]]; then
    cyan "==> Syncing host plugin to match tested version"
    if cmake --build "$HOST_BUILD_DIR" --target HexEditor >/tmp/test-ui-host-build.log 2>&1 \
       && cmake --install "$HOST_BUILD_DIR" >>/tmp/test-ui-host-build.log 2>&1; then
        cyan "    Host plugin updated. Restart Notepad++ on the host to load it."
    else
        yellow "    Host plugin sync failed; see /tmp/test-ui-host-build.log"
    fi
else
    yellow "==> Host CMake build dir not found at $HOST_BUILD_DIR; skipping host install."
    yellow "    Run 'cmake -S $REPO_ROOT/macos -B $HOST_BUILD_DIR' once to enable auto-sync."
fi

echo ""
if [[ $TEST_EXIT -eq 0 ]]; then
    cyan "==> Tests PASSED"
else
    red  "==> Tests FAILED (exit $TEST_EXIT)"
fi

[[ -f "$SUMMARY_MD" ]]      && cyan "Summary:    $SUMMARY_MD"
[[ -f "$DASHBOARD_HTML" ]]  && cyan "Dashboard:  $DASHBOARD_HTML  (open: test-ui.sh --dashboard)"
[[ -f "$DASHBOARD_MD" ]]    && cyan "Markdown:   $DASHBOARD_MD"

exit "$TEST_EXIT"
