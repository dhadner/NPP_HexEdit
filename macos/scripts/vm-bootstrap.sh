#!/usr/bin/env bash
# One-time bootstrap for a Parallels macOS VM (Apple Silicon) that runs the
# XCUITest UI suite for the NPP_HexEdit plugin.
#
# Run this AFTER:
#   1. macOS Setup Assistant is complete in the guest
#   2. Xcode is installed from the App Store and opened at least once
#      (so its license is accepted and CommandLineTools are wired up)
#   3. SSH is enabled (System Settings → General → Sharing → Remote Login)
#      and the host can reach the guest as `ssh npp-vm`
#
# What this script does:
#   - Installs Homebrew (Apple Silicon path /opt/homebrew)
#   - Installs xcodegen, cmake, git, rsync
#   - Verifies Xcode CommandLineTools are runnable
#
# What this script intentionally does NOT do (deprecated from older versions):
#   - Find the source tree on the shared folder. The host wrapper
#     (test-ui.sh) ssh-rsyncs the source directly into ~/vm-local/, so
#     there's no need to discover paths through the share.
#   - Write a ~/.npp-hexedit-vm.env file. All paths in vm-test.sh are now
#     constants (~/vm-local/NPP_HexEdit, /Applications/Nextpad++.app,
#     ~/build-NPP_HexEdit) — no env file needed.
#
# Usage (run from the VM):
#   bash ~/vm-bootstrap-local.sh
#
# Or from the host (test-ui.sh handles the rsync + invocation):
#   test-ui.sh --re-bootstrap

set -euo pipefail

BREW_PREFIX="/opt/homebrew"
BREW_BIN="$BREW_PREFIX/bin/brew"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || err "Run this inside a macOS guest."
[[ "$(uname -m)" == "arm64" ]] || err "Apple Silicon (arm64) only — assumes /opt/homebrew."

# Xcode + CLT
log "Verifying Xcode..."
xcode-select -p >/dev/null 2>&1 || err "Xcode CommandLineTools not selected. Install Xcode from the App Store first."
if ! xcodebuild -version >/dev/null 2>&1; then
    err "xcodebuild not runnable. Open Xcode once to accept the license, or run: sudo xcodebuild -license accept"
fi
log "Xcode: $(xcodebuild -version | head -1)"

# Homebrew
if [[ ! -x "$BREW_BIN" ]]; then
    log "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$($BREW_BIN shellenv)"
log "Homebrew: $($BREW_BIN --version | head -1)"

# Build deps
log "Installing build deps (xcodegen, cmake, git, rsync)..."
brew install xcodegen cmake git rsync 2>&1 | grep -vE "already installed|Warning:" || true

# Prepare the VM-local mirror directories so test-ui.sh's first rsync can target them.
mkdir -p "$HOME/vm-local"

# Clean up any stale env file from older bootstrap versions.
if [[ -f "$HOME/.npp-hexedit-vm.env" ]]; then
    log "Removing stale ~/.npp-hexedit-vm.env (no longer used)"
    rm -f "$HOME/.npp-hexedit-vm.env"
fi

# Clean up any old vm-test-local.sh / vm-bootstrap-local.sh in $HOME (the new
# workflow runs vm-test.sh from inside ~/vm-local/NPP_HexEdit/ instead).
for stale in "$HOME/vm-test-local.sh" "$HOME/vm-bootstrap-local.sh"; do
    if [[ -f "$stale" ]]; then
        # Keep vm-bootstrap-local.sh — that's the one we're running RIGHT NOW.
        # vm-test-local.sh is from the old workflow; remove it.
        case "$stale" in
            *vm-bootstrap-local.sh) ;;
            *) rm -f "$stale" ;;
        esac
    fi
done

log ""
log "Bootstrap complete."
log ""
log "First-run manual step — grant the test runner Accessibility permission:"
log "  1. From the host:  test-ui.sh testFooBar  (any single short test)"
log "  2. macOS will pop a dialog: Privacy & Security → Accessibility"
log "  3. Click 'Allow' for HexEditorUITests-Runner."
log "  4. Re-run the test; subsequent runs are unattended."
log ""
log "Day-to-day workflow (from the host):"
log "  test-ui.sh                          # all tests"
log "  test-ui.sh testFoo testBar          # subset"
log "  test-ui.sh --list                   # enumerate test names"
log "  test-ui.sh --dashboard              # open dashboard.html"
