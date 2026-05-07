# HexEditor macOS port scaffold

This directory contains the initial native plugin target for the Notepad++ macOS port. It builds `HexEditor.dylib` with the macOS plugin ABI from `NppPluginInterfaceMac.h`.

The current milestone is intentionally small: it loads in Notepad++ for macOS, adds plugin menu commands, reads the active Scintilla buffer, and toggles the active editor between the original Scintilla text view and an inline hex table with offset, byte, and ASCII columns. The table supports direct byte overwrite/append editing from the hex and ASCII columns, and can copy a traditional text dump to the clipboard. The original Windows project remains unchanged.

## Prerequisites

- macOS 11 or newer
- Xcode command line tools
- CMake 3.20 or newer
- A checkout of `nextpad-plus-plus`

By default, CMake expects the Nextpad++ host checkout to be a sibling of this
repository (both share a parent — the parent's name doesn't matter):

```text
<any-parent>/
  NPP_HexEdit/
  nextpad-plus-plus/
```

If it is elsewhere, pass `-DNPP_MACOS_DIR=/path/to/nextpad-plus-plus`.

## Build

```sh
cmake -S macos -B macos/build -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build
```

To build only for Apple Silicon:

```sh
cmake -S macos -B macos/build-arm64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build macos/build-arm64
```

## Install

```sh
cmake --install macos/build
```

The install target copies the plugin to:

```text
~/.notepad++/plugins/HexEditor/HexEditor.dylib
```

Restart Notepad++ for macOS after installing the plugin.

## Next porting steps

1. Extract reusable hex conversion and selection logic from the Windows `HEXDialog.cpp` implementation into platform-neutral C++.
2. Add range selection, cut/copy/paste, and delete behavior matching the Windows plugin.
3. Rebuild compare, find, goto, options, and pattern replace as native Cocoa controls.
4. Add toolbar assets and register them through the macOS plugin toolbar API.
