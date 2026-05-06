# HexEditor for Nextpad++ — v1.1.0

The first public release of the **HexEditor plugin for Nextpad++**. Distributed through the Nextpad++ plugin manager.

## Overview

HexEditor turns Nextpad++ into a hex editor without leaving the window. Toggle "View in HEX" on any open document and the active text view swaps for an inline grid: offset on the left, hex bytes in the middle, ASCII on the right. Toggle it back off and your text editor returns with every edit you made still applied — the hex view edits the same underlying buffer, not a separate representation.

Using the Plugins->HexEditor->Options->Startup dialog, you can specify file extensions that will automatically open in hex mode.

Once in hex mode you can:

- **Edit bytes directly** by typing in either the hex pane or the ASCII pane. Bit-precise editing in binary notation. Range selections with the mouse or keyboard (\<mouse drag\>, Shift+\<arrow keys\>, or Shift+\<PageUp/PageDown\>); rectangular (block) selections with Option+\<mouse drag\>, Shift+Option+\<arrow keys\>, or Shift+Option+\<PageUp/PageDown\>.
- **Undo / Redo** are fully supported.
- **Enhanced context menu.** Commands most commonly used are accessible on the context (right-click) menu as a convenience due to the different main menu location preferred by MacOS vs Windows.  In MacOS, the main menu is always at the top of the screen, sometimes far away from where you are working on a large monitor.  The context menu gives easy local access to menu items commonly needed during editing.
- **Cut / Copy / Paste** with semantics that match the Windows Notepad++ HEX-Editor's. Hex text is placed on the public clipboard so other apps can paste a useful string; raw bytes are also included so paste-back can round-trip losslessly. As an enhancement to the Windows version, multi-gigabyte Copy/Paste uses a promise / lazy-materialize scheme so a large Copy doesn't hold up the UI or balloon RAM usage.  This protocol is supported only by the hex view window.  Pasting large amounts of data into the main text window or another app will not silently truncate the data but will rather result in a clear message allowing you to try a different approach.
- **Find** ASCII text or hex byte patterns (auto-detected based on '0x' prefix). **Replace All** as one undo group.
- **Compare** the buffer against any file on disk and see differing bytes highlighted in red.
- **Insert Columns** to expand every row by a repeating hex pattern at a chosen column position.
- **Pattern Replace** to fill a selection (linear or rectangular) with a repeating pattern, with the rectangle path restarting the pattern at each row's first byte.
- **Switch view modes** between 8/16/32/64-bit grouping, hex / binary notation, big- / little-endian display order. Configure the address column width and number of columns per row. All preferences persist across launches via `NSUserDefaults`.

This is meant for the kinds of jobs for which you'd reach for `xxd`, `lldb memory read`, or a standalone hex editor: poking at binary file formats, reverse-engineering output, debugging serialization, patching a few bytes in a saved file. Doing it inside Nextpad++ means the buffer is always live — undo/redo stack intact, save to-disk wired up, and you can flip back to text view whenever you want.

## Lineage

This plugin descends from Jens Lorenz's original **HexEditor for Notepad++**, first released for Windows in 2006 and still maintained on the upstream [chcg/NPP_HexEdit](https://github.com/chcg/NPP_HexEdit) repo. The Windows source is included in this fork at [`HexEditor/`](HexEditor/) for reference and remains under its original GPLv2 license.

The macOS port (under [`macos/`](macos/)) is a from-scratch native rewrite — not a Wine wrapper, not a recompile of the Win32 source. It links against an AppKit-shaped plugin ABI and shares no runtime code with the Windows tree. What it does share is **feature semantics**: where the macOS and Windows plugins do the same thing (view modes, find/replace patterns, address-width range, pattern operations, clipboard byte conventions), they do it the same way; where they differ, it's a deliberate choice to fit Mac conventions — file-based Compare instead of Windows' split-pane Compare, Cmd+L for Goto. Those divergences are detailed in [CHANGELOG.md](CHANGELOG.md).

## Highlights

- **Inline hex view.** `NSTableView` overlay with offset / hex bytes / ASCII columns. Bookmark on the offset gutter, view-mode submenu (8/16/32/64-bit grouping; hex / binary notation; big- / little-endian display), configurable address width and columns. Bit-precise editing in binary mode.
- **Linear and rectangular selection.** Drag, Shift+click, or Shift+arrow / Shift+Page-Up/Down for linear; Option-drag (or Shift+Option, configurable) for rectangular. Shift+Option+arrows grow / shrink the rectangle. Cut / Copy / Paste / Delete and Pattern Replace work on either selection kind.
- **Multi-GB clipboard.** Copy / paste of multi-gigabyte hex selections doesn't serialize the buffer into pasteboard bytes — the plugin promises the data via `NSPasteboardTypeOwner` and materializes lazily on consumer request (or at quit time, after a Word-style "keep clipboard contents?" prompt above 16 MB). Find, Compare, and rectangular paste iterate via 256 KB `ByteSource` chunks straight off the Scintilla doc, so RAM use is O(window) not O(file).
- **Cross-app paste from debugger / hex-tool output.** Paste strips the address column and ASCII gloss from output of lldb (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA, C-string escape sequences, and C array literals. Just copy from the tool, paste into the hex view.
- **Strict-shape rectangular paste.** A rectangular payload requires a same-shape destination rect; mismatch shows a clarifying dialog. A custom pasteboard type carries the rect's shape and source-pane kind so a copy-then-paste round-trip preserves geometry.
- **Search and navigation.** Find (Cmd+F), Find and Replace (Cmd+Alt+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G). Auto-detects ASCII vs hex byte patterns (`0x` prefix or hex digits with separators trigger byte-pattern search). Go to Offset (Cmd+L) accepts decimal, `0x`-prefixed hex, and relative `+` / `-` offsets. Cmd+Home / Cmd+End jump to document edges; Shift+Cmd+arrow extends selection by line / to document edges.
- **Mac-native keyboard nav.** Bare Up / Down / Left / Right arrows scroll the viewport so the cursor never walks off-screen. Page Up / Down keep at least one row of any active selection visible. Asymmetric Left / Right byte-stride matches Windows: from nibble 0 Left moves a full byte; from nibble 1 it moves one nibble back.
- **File-based Compare HEX.** Pick any file via the system Open panel; differing bytes highlight in red; one click clears the result.
- **Pattern operations.** Insert Columns (inject a hex pattern into every row at a chosen column position) and Pattern Replace (fill a selection with a repeating pattern, restarting at each row's first byte for rectangular selections).
- **Mac-native appearance.** Semantic `NSColor` values throughout, so dark mode and accent colors follow the host with zero plugin-side code. No font / color pickers — appearance is the host's job.
- **Localized.** 15 `.strings` files: full translations for English, German, Spanish, French, Italian, Polish, Russian, Ukrainian, Simplified Chinese, Hebrew, and Arabic; regional overrides for British, American, Peninsular Spanish, and Mexican Spanish. Cascade falls through exact tag → base tag → next preferred language → embedded English defaults. The About dialog shows which file the runtime is using and links to [LOCALIZATION.md](LOCALIZATION.md) on GitHub to help users whose language isn't yet supported create their own localization file(s).
- **RTL support.** Menus and dialogs auto-flip under Hebrew and Arabic. The hex view itself stays LTR (hex dumps are universally read left-to-right even by RTL-language developers, so flipping would break the canonical form).
- **Two-finger pinch / Cmd+Scroll zoom.** Discrete steps; algorithm matches Scintilla's so the gesture feels identical to the host's main text editor.

## Install

The plugin ships through the Nextpad++ plugin manager — install it from there. To build from source instead:

```sh
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
```

Restart Nextpad++. The plugin appears as **Plugins → HexEditor** with seven entries: View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Options, and Help.

The build expects a checkout of `notepad-plus-plus-macos` next to this repo; pass `-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` if it lives elsewhere.

See [CHANGELOG.md](CHANGELOG.md) for more detailed information on differences from the Windows version.

## Tests

Five tiers, all green at release. Live status of the most recent developer-machine run is published at [docs/test-status.md](docs/test-status.md) (regenerated by the pre-commit script and committed to the repo — there's no CI equivalent because the UI tier needs a Parallels VM that GitHub-hosted runners can't provide).

- **HexCore unit tests** — pure C++, ~9,200 assertions across 37 suites covering selection math, view-mode rendering, clipboard parsing, and pattern operations. Milliseconds. `ctest -L unit`.
- **Unit tests under ASan + UBSan** — same suite rebuilt with AddressSanitizer and UndefinedBehaviorSanitizer to catch memory and signed-overflow bugs the release build would silently tolerate. Sub-second. `ctest -L unit` against the sanitized build.
- **Plugin smoke tests** — `dlopen`s the dylib, asserts the NPP exports, the menu shape, and English titles. Sub-second. `ctest -L smoke`.
- **Fuzz / robustness** — eight libFuzzer harnesses running 30 s each (~4 minutes total) under ASan + UBSan against the plugin's external-input parsers. Four cover the rectangular-clipboard path (rect-payload decode, rect-clipboard text parse, rect-selection construction, rect-byte extraction); four cover the broader external-input surface (cross-app paste cleaner that handles lldb/gdb/xxd/x64dbg/IDA/C-escape/C-array output, Find/Replace pattern parser, linear hex-clipboard parser, Goto-Offset expression parser). Together they exercise every untrusted-text boundary the plugin exposes; the suite has logged ~30M+ iterations per run with zero crashes since the v1.1.0 release gate. `ctest -L fuzz`.
- **XCTest UI** — full suite against the running Nextpad++.app: toggle, undo/redo, append-at-EOF, cut/copy/paste/delete round-trips (linear and rectangular, including 1.5 GB scale), rectangle drag and extend, view-submode rendering, all dialog flows, bit-precise editing, mirror-cursor rendering, and the localization cascade for all 15 shipped tags + an unsupported-language fallback. ~46 minutes on a Parallels VM. `ctest -L ui` (best run inside a Parallels VM per [DEVELOPER.md](DEVELOPER.md) — the suite locks the host keyboard and mouse for the duration).

The pre-commit suite (`macos/scripts/pre-commit-tests.sh`) runs all five tiers in fastest-first order and is the required gate before merging to master.  It automatically dispatches the `ctest -L ui` tests to the Parallels VM to avoid locking the host keyboard and mouse.

## License

GPLv2, inherited from the original Jens Lorenz source. See [LICENSE](LICENSE).
