# NPP_HexEdit
Notepad++ Plugin Hexedit

This is an unofficial repo with source code from:  
https://sourceforge.net/projects/npp-plugins/files/Hex%20Editor/


Build Status
------------

Github `VS2022`  [![Build status](https://github.com/chcg/NPP_HexEdit/actions/workflows/CI_build.yml/badge.svg)](https://github.com/chcg/NPP_HexEdit/actions/workflows/CI_build.yml)


Related repos on GitHub:
- https://github.com/JetNpp/HexEditor
- https://github.com/mackwai/NPPHexEditor

macOS port scaffold
-------------------

An initial native macOS plugin target lives in [macos/](macos/). It builds `HexEditor.dylib` for the Notepad++ macOS port using CMake and `NppPluginInterfaceMac.h`.

The current macOS milestone is a loadable plugin with menu commands for toggling the active editor between the original Scintilla text view and an inline hex table, or copying a hex dump of the active Scintilla buffer. The hex view separates offsets, byte columns, and ASCII text, and supports direct byte overwrite/append editing from the hex and ASCII columns. It is not yet a full replacement for the Windows HEX editor UI.

Build it with:

```sh
cmake -S macos -B macos/build -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build
```

Install it with:

```sh
cmake --install macos/build
```

By default, the CMake target expects a sibling checkout of `notepad-plus-plus-macos`. If that checkout is somewhere else, pass `-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` when configuring.
