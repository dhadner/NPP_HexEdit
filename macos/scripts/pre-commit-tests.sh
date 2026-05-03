#!/usr/bin/env bash
# Canonical pre-commit gate. Runs every test tier in dependency order,
# fastest first; aborts at the first failing tier so a 5 ms unit-tier
# regression doesn't burn 22 minutes of UI run before being noticed.
#
# Run from the repo root:
#   bash macos/scripts/pre-commit-tests.sh
#
# Tiers (cumulative time ~25 min on a quiet machine):
#   1. Unit (host)              ~0.01 s — ctest -L unit
#   2. Unit + ASan/UBSan (host) ~0.5  s — ctest -L unit (sanitized build)
#   3. Plugin smoke (host)      ~0.4  s — ctest -L smoke (dlopen contract)
#   4. Fuzz / robustness (host) ~2    min — 4 libFuzzer harnesses × 30 s
#   5. Full XCTest UI (VM)      ~22   min — test-ui.sh, locks VM kbd/mouse
#
# Tiers 1-4 run on the host. Tier 5 SSH-routes to the Parallels VM (per
# feedback_xctest_ui_runs.md — never run UI tests on the host since the
# session locks keyboard and mouse for the duration). Each tier rebuilds
# its target if needed, so the script doesn't assume any pre-existing
# build state beyond `cmake -S macos -B macos/build*` having been
# configured at least once for each tier's build directory.
#
# Build directories the script expects (configure each once, after which
# the script keeps them up-to-date via cmake --build):
#   macos/build       — release build (unit, smoke targets)
#   macos/build-asan  — sanitized build (unit-asan target)
#   macos/build-fuzz  — fuzz build (libFuzzer harnesses, requires brew llvm)
#
# If any of those directories are missing, the script prints the configure
# command for that tier and bails. Cf. macos/TESTING.md "Pre-commit
# checklist" for first-time setup.
#
# Exit codes:
#   0 — every tier passed; safe to commit
#   non-0 — at least one tier failed; script also prints which tier and
#           where its log lives for follow-up
#
# Options:
#   --skip-ui — run host tiers (1-4) only. Useful as a fast pre-push gate;
#               full sequence (incl. UI) is still required before commit.
#   --skip-fuzz — skip the 2-min fuzz tier. Reserve for cosmetic-only
#                 commits (whitespace, comments) where parser fuzz coverage
#                 is irrelevant. Default behaviour runs it.
#   --verbose — stream each tier's full output to the terminal (also tee'd
#               to the log file). Default: only one progress line per tier
#               in the terminal; full output goes to logs only.
#
# Logs:
#   Each tier writes to /tmp/pre-commit-tests-<pid>/<N>-<name>.log so a
#   failed tier's full output is preserved for follow-up. The script prints
#   the log path on success and the tail-of-log + path on failure.

set -euo pipefail

cyan()    { printf '\033[1;36m%s\033[0m\n' "$*"; }
yellow()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()     { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green()   { printf '\033[1;32m%s\033[0m\n' "$*"; }

SKIP_UI=0
SKIP_FUZZ=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --skip-ui)   SKIP_UI=1 ;;
        --skip-fuzz) SKIP_FUZZ=1 ;;
        --verbose)   VERBOSE=1 ;;
        -h|--help)
            sed -nE 's/^# ?//p' "$0" | sed -n '1,/^$/p'
            exit 0
            ;;
        *)
            red "unknown flag: $arg"
            red "see: pre-commit-tests.sh --help"
            exit 2
            ;;
    esac
done

# Per-run log directory; isolated so concurrent runs don't trample logs.
LOG_DIR="/tmp/pre-commit-tests-$$"
mkdir -p "$LOG_DIR"
cyan "==> Logs: $LOG_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

require_build_dir() {
    local dir="$1"
    local hint="$2"
    if [[ ! -f "$dir/CMakeCache.txt" ]]; then
        red "error: $dir not configured."
        red "       Run: $hint"
        exit 2
    fi
}

# Run one tier:
#   $1 = human label (e.g. "1/5 unit (host)")
#   $2 = log filename stem (e.g. "1-unit") — used to build $LOG_DIR/$2.log
#   $3..$N = command + args to invoke
# Default: pipes output to log only, prints one-line progress to terminal.
# --verbose: tees output to terminal AND log so you can watch it live.
# On failure: prints the tail of the log so the cause is visible without
#   cating around for the file.
run_tier() {
    local label="$1"
    local logname="$2"
    shift 2
    local logfile="$LOG_DIR/$logname.log"
    cyan "==> [$label]"
    local rc=0
    if [[ $VERBOSE -eq 1 ]]; then
        # set -o pipefail makes tee's failure (which can't happen here)
        # mask the real exit, so capture the inner command's status
        # explicitly via PIPESTATUS instead.
        "$@" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
    else
        "$@" >"$logfile" 2>&1 || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        green "    PASSED  ($logfile)"
    else
        red   "    FAILED ($label) — exit $rc"
        if [[ $VERBOSE -ne 1 ]]; then
            red   "    Last 30 lines of $logfile:"
            tail -30 "$logfile" >&2 || true
        fi
        red   "    Full log: $logfile"
        red   "    Fix this tier before re-running pre-commit-tests.sh."
        exit 1
    fi
}

# ---- Tier 1: unit (host, ~0.01 s) ----------------------------------------

require_build_dir "macos/build" \
    "cmake -S macos -B macos/build -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos"

run_tier "1/5 unit (host)" "1-unit" \
    ctest --test-dir macos/build -L unit --output-on-failure

# ---- Tier 2: unit under ASan + UBSan (host, ~0.5 s) ----------------------

require_build_dir "macos/build-asan" \
    "cmake -S macos -B macos/build-asan -DENABLE_SANITIZERS=ON -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos"

run_tier "2/5 unit + ASan/UBSan (host)" "2-unit-asan" \
    ctest --test-dir macos/build-asan -L unit --output-on-failure

# ---- Tier 3: plugin smoke (host, ~0.4 s) ---------------------------------

run_tier "3/5 plugin smoke (host)" "3-smoke" \
    ctest --test-dir macos/build -L smoke --output-on-failure

# ---- Tier 4: fuzz / robustness (host, ~2 min) ----------------------------

if [[ $SKIP_FUZZ -eq 1 ]]; then
    yellow "==> [4/5 fuzz (host)] SKIPPED via --skip-fuzz"
else
    require_build_dir "macos/build-fuzz" \
        "cmake -S macos -B macos/build-fuzz -DENABLE_FUZZ_TESTS=ON -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++ -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos"
    run_tier "4/5 fuzz / robustness (host)" "4-fuzz" \
        ctest --test-dir macos/build-fuzz -L fuzz --output-on-failure
fi

# ---- Tier 5: full XCTest UI on VM (~22 min) ------------------------------

if [[ $SKIP_UI -eq 1 ]]; then
    yellow "==> [5/5 UI (VM)] SKIPPED via --skip-ui — host tiers green only"
    yellow "    Full sequence including UI is still required before commit."
    yellow "    Logs: $LOG_DIR"
    exit 0
fi

yellow "    UI tier locks the VM kbd/mouse for ~22 min — don't use the VM until done."
yellow "    Ctrl+C on this terminal to abort cleanly (killing only the VM-side test"
yellow "    won't stop the host wrapper's post-test housekeeping)."
run_tier "5/5 UI suite (VM, ~22 min)" "5-ui" \
    bash macos/scripts/test-ui.sh

# ---- All tiers green -----------------------------------------------------

green ""
green "All pre-commit tiers green. Safe to commit."
cyan  "Logs: $LOG_DIR"
