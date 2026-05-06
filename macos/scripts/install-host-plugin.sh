#!/usr/bin/env bash
# Install the freshly-built HexEditor.dylib + all Localizable.*.strings
# from macos/build/ into the host's ~/.notepad++/plugins/HexEditor/
# directory so a relaunched Notepad++.app picks up the new build.
#
# Used during iterative dev (build, install, restart NPP, verify) and as
# a single Bash-allow target so Claude Code doesn't have to authorize a
# multi-cp compound on every iteration.
#
# Idempotent. Errors out cleanly if the build hasn't been done yet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/macos/build"
INSTALL_DIR="$HOME/.notepad++/plugins/HexEditor"

if [[ ! -f "$BUILD_DIR/HexEditor.dylib" ]]; then
    echo "error: $BUILD_DIR/HexEditor.dylib not found." >&2
    echo "       Run 'cmake --build $BUILD_DIR --target HexEditor' first." >&2
    exit 2
fi

mkdir -p "$INSTALL_DIR"

cp "$BUILD_DIR/HexEditor.dylib" "$INSTALL_DIR/HexEditor.dylib"

# All shipped locales — copy whatever the build produced. (`shopt -s nullglob`
# so an empty match is a no-op rather than a literal path.)
shopt -s nullglob
strings_files=("$BUILD_DIR"/Localizable.*.strings)
shopt -u nullglob
if [[ ${#strings_files[@]} -gt 0 ]]; then
    cp "${strings_files[@]}" "$INSTALL_DIR/"
fi

# Brief confirmation — what got installed and when.
printf '==> Installed HexEditor plugin to %s\n' "$INSTALL_DIR"
stat -f "    %Sm  %N" "$INSTALL_DIR/HexEditor.dylib" "$INSTALL_DIR"/Localizable.*.strings
echo "    (Quit + relaunch Notepad++ to pick up the new build.)"
