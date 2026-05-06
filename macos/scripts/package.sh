#!/usr/bin/env bash
# Build the HexEditor plugin and produce the distribution .zip. Thin
# wrapper around the CMake POST_BUILD packaging step in macos/CMakeLists.txt
# (which is the source of truth for the version, dylib, .strings, and PNGs
# that go into the archive).
#
# Run from the repo root:
#   bash macos/scripts/package.sh
#
# The resulting zip path is printed at the end; its filename embeds the
# project version from macos/CMakeLists.txt:7.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/macos/build"

cmake --build "${BUILD_DIR}" --target HexEditor

# Resolve the produced zip via a glob so the script doesn't need to know
# (or duplicate) the version — CMakeLists.txt:7 is the single source.
# `ls -t` puts the freshest first, which matters if a stale zip from a
# previous version is still in the build dir.
ls -t "${BUILD_DIR}"/nppHexEditorPlugin-*.zip | head -n 1
