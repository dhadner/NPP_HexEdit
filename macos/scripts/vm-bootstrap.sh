#!/usr/bin/env bash
# One-time bootstrap for a Parallels macOS VM (Apple Silicon) that runs the
# XCUITest UI suite for the NPP_HexEdit plugin. Run this AFTER:
#   1. macOS Setup Assistant is complete in the guest
#   2. Xcode is installed from the App Store and opened at least once
#      (so its license is accepted and CommandLineTools are wired up)
#   3. The host's parent GitHub directory is shared into the guest via
#      Parallels (VM Settings → Sharing → Custom Folders → add the folder
#      that contains both NPP_HexEdit and notepad-plus-plus-macos)
#
# What this does:
#   - Installs Homebrew (Apple Silicon path /opt/homebrew)
#   - Installs xcodegen, cmake, git
#   - Locates the NPP_HexEdit checkout via the shared folder mount
#   - Builds the plugin to a VM-LOCAL build directory (~/build-NPP_HexEdit)
#     so the shared filesystem doesn't slow each compile
#   - Installs the plugin to ~/.notepad++/plugins/HexEditor/ in the guest
#   - Runs the unit + smoke tiers as a sanity check
#
# Usage:
#   ./vm-bootstrap.sh                          # auto-detect shared folder
#   ./vm-bootstrap.sh /path/to/NPP_HexEdit     # explicit path
#
# After this script finishes successfully:
#   1. Grant Accessibility permission to Xcode in the guest:
#      System Settings → Privacy & Security → Accessibility → enable Xcode
#   2. Use ./vm-test.sh to run UI tests.

set -euo pipefail

BREW_PREFIX="/opt/homebrew"
BREW_BIN="$BREW_PREFIX/bin/brew"
BUILD_DIR="$HOME/build-NPP_HexEdit"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || err "Run this inside a macOS guest."
[[ "$(uname -m)" == "arm64" ]] || err "Apple Silicon (arm64) only — this script assumes /opt/homebrew."

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
log "Installing build deps (xcodegen, cmake, git)..."
brew install xcodegen cmake git 2>&1 | grep -vE "already installed|Warning:" || true

# Locate the shared NPP_HexEdit checkout.
NPP_HEXEDIT="${1:-}"
if [[ -z "$NPP_HEXEDIT" ]]; then
    log "Searching common Parallels shared-folder mount points for NPP_HexEdit..."
    # Parallels' macOS-on-macOS shared folders tend to land in one of these
    # depending on Parallels version, the host user name, and which folder the
    # user shared. We probe several before giving up.
    candidates=(
        "$HOME/Parallels Shared Folders"
        "/Volumes/My Shared Files"
        "/Volumes"
    )
    for root in "${candidates[@]}"; do
        if [[ -d "$root" ]]; then
            found=$(find "$root" -maxdepth 5 -type d -name "NPP_HexEdit" 2>/dev/null | head -1 || true)
            if [[ -n "$found" && -d "$found/macos" ]]; then
                NPP_HEXEDIT="$found"
                break
            fi
        fi
    done
fi
[[ -n "$NPP_HEXEDIT" && -d "$NPP_HEXEDIT/macos" ]] || \
    err "NPP_HexEdit checkout not found. Pass its path explicitly: ./vm-bootstrap.sh /path/to/NPP_HexEdit"
log "Repo: $NPP_HEXEDIT"

# Sibling notepad-plus-plus-macos must live next to NPP_HexEdit (the CMake config expects this).
NPP_MACOS="$(dirname "$NPP_HEXEDIT")/notepad-plus-plus-macos"
[[ -d "$NPP_MACOS" ]] || \
    err "Sibling notepad-plus-plus-macos not found at $NPP_MACOS. Share the parent GitHub directory, not just NPP_HexEdit."
log "Host: $NPP_MACOS"

# The host build is needed for UI tests. If the host (your physical Mac) already
# built Notepad++.app and the build folder is shared, we can use it directly.
NPP_APP="$NPP_MACOS/build/Notepad++.app"
if [[ -d "$NPP_APP" ]]; then
    log "Found Notepad++.app at $NPP_APP (built on the host, shared in)"
else
    log "WARNING: Notepad++.app not found at $NPP_APP."
    log "        UI tests need the host app. Either build it on your physical Mac"
    log "        before running tests, or build it inside the VM separately."
fi

# Build the plugin to a VM-local build directory. Source lives in the shared
# folder; build outputs in $HOME so each rebuild doesn't traverse the slow
# shared filesystem.
log "Configuring plugin build at $BUILD_DIR..."
cmake -S "$NPP_HEXEDIT/macos" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DNPP_MACOS_DIR="$NPP_MACOS"

log "Building HexEditor.dylib..."
cmake --build "$BUILD_DIR"

log "Installing plugin to ~/.notepad++/plugins/HexEditor/..."
cmake --install "$BUILD_DIR"

# Sanity tests — these don't need the host app and finish in <1s.
log "Running unit + smoke tiers..."
ctest --test-dir "$BUILD_DIR" -L "unit|smoke" --output-on-failure

# Persist the discovered path so vm-test.sh can find it without re-searching.
cat > "$HOME/.npp-hexedit-vm.env" <<EOF
# Generated by vm-bootstrap.sh on $(date)
export NPP_HEXEDIT="$NPP_HEXEDIT"
export NPP_MACOS="$NPP_MACOS"
export BUILD_DIR="$BUILD_DIR"
EOF
log "Wrote $HOME/.npp-hexedit-vm.env"

log ""
log "Bootstrap complete."
log ""
log "Final manual step — grant Accessibility permission to Xcode:"
log "  System Settings → Privacy & Security → Accessibility → enable Xcode"
log "(XCUITest synthesizes mouse/keyboard events; the OS gates this.)"
log ""
log "Then run: $NPP_HEXEDIT/macos/scripts/vm-test.sh"
