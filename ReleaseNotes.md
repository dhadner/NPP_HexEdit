# HexEditor for Nextpad++ — v1.1.0

The first public release of the macOS-native HexEditor plugin for
Notepad++ — Jens Lorenz's Windows plugin from 2006, ported and rewritten
for AppKit. Distributed through the Nextpad++ plugin manager.

## What it is

An inline hex view that swaps the active editor for an offset / hex
bytes / ASCII grid. Direct byte editing, range and rectangular
selection, find/replace, file-based compare, and pattern operations —
all reachable via the Plugins menu and a context menu over the hex
view.

The macOS port is a from-scratch native rewrite, not a Wine wrapper
around the Windows binary. It links against an AppKit-shaped plugin
ABI and shares no runtime code with the Windows tree (which remains
in `HexEditor/` for reference). Where the macOS and Windows plugins
do the same thing, they do it the same way; where they differ, it's a
deliberate choice to fit Mac conventions (see "Differences from the
Windows version" below).

## Highlights

- **Inline hex view.** `NSTableView` overlay with offset / hex bytes /
  ASCII columns. Bookmark on the offset gutter, view-mode submenu
  (8/16/32/64-bit grouping; hex / binary notation; big- / little-
  endian display), configurable address width and columns.
  Bit-precise editing in binary mode.
- **Linear and rectangular selection.** Drag, Shift+click, or
  Shift+arrow / Shift+Page-Up/Down for linear; Option-drag (or
  Shift+Option, configurable) for rectangular. Shift+Option+arrows
  grow / shrink the rectangle. Cut / Copy / Paste / Delete and
  Pattern Replace work on either selection kind.
- **Multi-GB clipboard.** Copy / paste of multi-gigabyte hex
  selections doesn't serialise the buffer into pasteboard bytes — the
  plugin promises the data via `NSPasteboardTypeOwner` and
  materialises lazily on consumer request (or at quit time, after a
  Word-style "keep clipboard contents?" prompt above 16 MB). Find,
  Compare, and rectangular paste iterate via 256 KB `ByteSource`
  chunks straight off the Scintilla doc, so RAM use is O(window) not
  O(file).
- **Cross-app paste from debugger / hex-tool output.** Paste strips
  the address column and ASCII gloss from output of lldb
  (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA, C-string escape
  sequences, and C array literals. Just copy from the tool, paste
  into the hex view.
- **Strict-shape rectangular paste.** A rectangular payload requires
  a same-shape destination rect; mismatch shows a clarifying dialog.
  A custom pasteboard type carries the rect's shape and source-pane
  kind so a copy-then-paste round-trip preserves geometry.
- **Search and navigation.** Find (Cmd+F), Find and Replace
  (Cmd+Alt+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G).
  Auto-detects ASCII vs hex byte patterns (`0x` prefix or hex digits
  with separators trigger byte-pattern search). Go to Offset (Cmd+L)
  accepts decimal, `0x`-prefixed hex, and relative `+` / `-` offsets.
  Cmd+Home / Cmd+End jump to document edges; Shift+Cmd+arrow extends
  selection by line / to document edges.
- **Mac-native keyboard nav.** Bare Up / Down / Left / Right arrows
  scroll the viewport so the cursor never walks off-screen. Page Up
  / Down keep at least one row of any active selection visible.
  Asymmetric Left / Right byte-stride matches Windows: from nibble 0
  Left moves a full byte; from nibble 1 it moves one nibble back.
- **File-based Compare HEX.** Pick any file via the system Open
  panel; differing bytes highlight in red; one click clears the
  result.
- **Pattern operations.** Insert Columns (inject a hex pattern into
  every row at a chosen column position) and Pattern Replace (fill
  a selection with a repeating pattern, restarting at each row's
  first byte for rectangular selections).
- **Mac-native appearance.** Semantic `NSColor` values throughout,
  so dark mode and accent colours follow the host with zero plugin-
  side code. No font / colour pickers — appearance is the host's
  job.
- **Localized.** 15 `.strings` files: full translations for English,
  German, Spanish, French, Italian, Polish, Russian, Ukrainian,
  Simplified Chinese, Hebrew, and Arabic; regional overrides for
  British, American, Peninsular Spanish, and Mexican Spanish.
  Cascade falls through exact tag → base tag → next preferred
  language → embedded English defaults. The About dialog shows which
  file the runtime is using and links to
  [LOCALIZATION.md](LOCALIZATION.md) on GitHub for users whose
  language isn't yet supported.
- **RTL support.** Menus and dialogs auto-flip under Hebrew and
  Arabic. The hex view itself stays LTR (hex dumps are universally
  read left-to-right even by RTL-language developers, so flipping
  would break the canonical form).
- **Two-finger pinch / Cmd+Scroll zoom.** Discrete steps; algorithm
  matches Scintilla's so the gesture feels identical to the host's
  main text editor.

## Install

The plugin ships through the Nextpad++ plugin manager — install
it from there. To build from source instead:

```sh
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
```

Restart Nextpad++. The plugin appears as **Plugins → HexEditor**
with seven entries: View in HEX, Compare HEX, Clear Compare Result,
Insert Columns, Pattern Replace, Options, and Help.

The build expects a checkout of `notepad-plus-plus-macos` next to this
repo; pass `-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` if it
lives elsewhere.

## Differences from the Windows version

The macOS port deliberately diverges from the Windows plugin in a
handful of places — every divergence preserves Windows feature
semantics while adopting the platform-native shape:

- **Compare HEX picks a file from disk** instead of comparing the two
  panes of a split-view editor. Nextpad++ doesn't expose a
  plugin API for reading a second split pane's contents; the
  file-picker approach also makes "compare my unsaved edits against
  the saved version" a one-step workflow.
- **Goto Offset** is reached via Cmd+L (matches macOS browser/Pages
  convention) and a context-menu entry.
- **No `Capital` preference.** Copy emits lowercase hex text; on-
  screen rendering is lowercase too.
- **No font / colour pickers in Options.** Plugin colours are
  semantic and follow the host automatically; the host owns
  appearance via `NSAppearance` + Style Configurator.
- **Toolbar registration** isn't wired yet — the toolbar PNGs ship in
  the install directory ready for the host's eventual toolbar-
  registration API.
- **macOS-only context-menu additions:** Undo / Redo and Zoom In /
  Out / Restore Default Zoom. Useful on macOS where Cmd+Plus to zoom
  is universally expected.

See [CHANGELOG.md](CHANGELOG.md) for the full divergence list and the
engineering-notes section.

## Tests

Three tiers, all green at release.

- **HexCore unit tests** — pure C++, ~750 assertions. Milliseconds.
  `ctest -L unit`.
- **Plugin smoke tests** — `dlopen`s the dylib, asserts the NPP
  exports, the menu shape, and English titles. `ctest -L smoke`.
- **XCTest UI** — full suite against the running Nextpad++.app:
  toggle, undo/redo, append-at-EOF, cut/copy/paste/delete round-
  trips (linear and rectangular, including 1.5 GB scale), rectangle
  drag and extend, view-submode rendering, all dialog flows,
  bit-precise editing, mirror-cursor rendering, and the localization
  cascade for all 13 shipped tags + an unsupported-language fallback.
  Runs via `macos/ui-tests-xcode/run-tests.sh` (or in a Parallels VM
  per [DEVELOPER.md](DEVELOPER.md) to avoid locking your keyboard for
  ~14 minutes).

The pre-commit suite (`macos/scripts/pre-commit-tests.sh`) runs all
five tiers (unit, unit+ASan/UBSan, smoke, fuzz, full UI) and is the
required gate before merging to master.

## Known limitations

- **Rectangular paste at a bare caret** is intentionally not
  supported — the strict-shape rule requires a same-shape destination
  rect. A future release may add an opt-in "auto-create destination
  from clipboard shape at caret" behaviour; for now the safer rule
  wins.
- **Multiple rectangular selections** (Scintilla-style) and
  **column-mode typing** across a rectangle are not on the v1.1.x
  roadmap.
- The hex view is intentionally pinned LTR even under Hebrew and
  Arabic — hex dumps are universally read left-to-right and flipping
  the table would break the canonical form for RTL-language
  developers. All other surfaces (menus, NSAlert dialogs, the four
  Options dialog tabs, the host's window chrome) flip naturally.
- The plugin still tracks Nextpad++ upstream API growth — see
  CHANGELOG for items that depend on host-side plumbing not yet
  exposed (e.g. comparing two split panes, intercepting
  `IDM_SEARCH_GOTOLINE`, toolbar registration).

## License

GPLv2, inherited from the original Jens Lorenz source. See
[HexEditor/license.txt](HexEditor/license.txt).
