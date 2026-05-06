# Changelog

This file lists what's changed in the macOS port of the HexEditor plugin. The
original Windows version, kept untouched in [HexEditor/](HexEditor/), has its
own history in [HexEditor/change.log](HexEditor/change.log).

## v1.1.0 — first public release

The macOS port of Jens Lorenz's HexEditor — the venerable Notepad++
plugin from 2006 — now runs natively on macOS and is distributed
through the Notepad++ macOS plugin manager. v1.1.0 is the debut public
release; the v1.0.0 git tag below predates the host's plugin manager
and was never installed by users.

### Background

The plugin you're installing is an inline hex view that swaps the active
Scintilla editor for an offset / hex-bytes / ASCII grid. It's a native
rewrite — no wine, no shim — that links against an AppKit-shaped plugin
ABI and shares no runtime code with the Windows tree (which remains
untouched in [HexEditor/](HexEditor/) for reference). The shared
substance is feature semantics: when the macOS port and the Windows
plugin do the same thing (find/replace, view-mode submenus,
address-width range, pattern operations), they do it the same way; when
they differ, it's a deliberate choice to fit Mac conventions —
documented under "Divergences from Windows" below.

### Design philosophy

- **Mac-native shape, Windows-native feature semantics.** Dialogs are
  NSAlert / NSPanel, not Win32 modals. Menus follow macOS conventions
  (Cmd+L for goto, Cmd+F for find, Shift+Cmd+arrow for extend).
  Appearance is semantic (`NSColor.systemRedColor`,
  `unemphasizedSelectedContentBackgroundColor`) so dark mode and accent
  colours follow the host with zero code in the plugin. The Windows
  plugin's bold/italic/colour pickers are absent on purpose — the host
  owns appearance.
- **Hex layout stays LTR.** Even under right-to-left locales (none
  shipped yet), the hex view keeps Offset on the left and ASCII on the
  right. Hex dumps are universally LTR — that's how every hex tool
  from `xxd` to Hex Fiend reads, and how every Hebrew/Arabic-speaking
  developer reads them.
- **Test coverage as a contract.** Every translator-facing string has a
  cascade UI test asserting the loader picks the right file. Every
  multi-GB capability has a paste / compare scaling test. Every
  rectangular-selection edge case has a HexCore unit test. The
  pre-commit suite (unit + ASan + smoke + fuzz + full UI) gates merges
  to master.

### What's in the box

#### Editing & selection

- **Inline hex view** — `NSTableView` overlay swaps the active Scintilla view for an offset / hex bytes / ASCII grid. Direct byte overwrite + append editing in both panes. Bookmark toggling on the offset gutter. Cursor and selection mirror the underlying Scintilla buffer when toggled — open the hex view from any text-mode position and the byte cursor lands at the corresponding offset; selections survive the round-trip with the hex caret at the end of the selected range.
- **Linear selection** across hex and ASCII panes via mouse drag, Shift+click, or Shift+arrow / Shift+Page-Up/Down keystrokes. Page Up / Down scroll a full viewport page; the selection-visible safety net keeps at least one row of the active selection on screen (Cmd+A places the cursor on the row past the selection, so cursor-visibility alone isn't enough).
- **Rectangular (block) selection** — Option-drag (or Shift+Option, configurable in Options) inside the hex pane or ASCII pane draws a 2D rectangle (cell-granular). Shift+Option+arrow keys grow / shrink the rectangle from the dragged-to corner; the first such press while no rect is active bootstraps a 1×1 rect at the caret. Plain arrow / Home / End / typing any character collapses the rect (typing replaces it with normal byte editing at the cursor). The address column is not selectable — clicks toggle a bookmark.
- **Cut / Copy / Paste / Delete on a rectangle** — Copy emits a public-text fallback (space-separated hex bytes per row, joined by `\n`) and a custom pasteboard type `org.notepad-plus-plus.HexEditor.rectangular` carrying a `kind` tag (Bytes / Ascii) plus the rectangle's shape. Round-tripping through the plugin's clipboard preserves geometry. Delete is zero-fill (file size unchanged, offsets preserved).
- **Strict-shape rectangular paste** — pasting a rectangular payload requires the destination to be a rectangle of the exact same width × height. Mismatch shows a clarifying dialog naming the required dimensions. External text-only clipboards (no custom UTI) are parsed as `\n`-separated rows per the same rules; single-line text falls through to the existing linear paste so cross-app workflows are unaffected.
- **Bit-precise editing in binary notation** — typing `0` or `1` in Binary view edits one bit at the caret (MSB-first within the byte) and advances by one bit.
- **Asymmetric Left / Right keystroke nav** — from the first nibble of a byte, Left moves one full byte; from the second nibble, Left moves one nibble back to the first nibble of the same byte. Right always advances one byte. Matches the Windows plugin's [HEXDialog.cpp](HexEditor/src/HEXDialog.cpp) keystroke semantics. Bare arrows scroll the viewport so the cursor never walks off-screen.
- **Mirror cursor** — the inactive pane (hex or ASCII) shows the byte/character at the cursor as a 2-pixel underline by default, or as a full rectangle if the Mirror toggle is enabled in Options.
- **Cmd+Home / Cmd+End** jump to document edges. **Shift+Cmd+arrow** extends selection by line / to document edges. Bare `End` only reaches end-of-row; document-end requires `Cmd+End`.

#### Clipboard & multi-GB scale

- **Cut / Copy / Paste / Delete with Windows-faithful semantics.** Copy from the hex pane writes lowercase space-separated hex text (`"de ad be ef"`) and publishes raw bytes under `public.data` so paste back into the hex view round-trips losslessly. Copy from the ASCII pane writes UTF-8 text. Paste auto-detects: tries `public.data`, then parses pasteboard text as hex (`"DE AD"`, `"deadbeef"`, `"0xDE,0xAD"` all accepted), then falls through to UTF-8 bytes. Edit menu integration via responder-chain routing.
- **Cut Binary Content / Copy Binary Content / Paste Binary Content** always operate on raw bytes (matches the Windows menu entries).
- **Multi-GB scale.** Copy of a large hex selection doesn't eagerly serialise the whole buffer into pasteboard bytes. The plugin promises the data via `NSPasteboardTypeOwner` and materialises it lazily on consumer request (or at HexEditor quit time, after a Word-style "keep clipboard contents?" prompt that triggers above 16 MB). In-process paste short-circuits via `currentlyOwnedHexSnapshot()` checking `changeCount`, so hex→hex copy/paste at 1.5 GB scale completes without ever serialising. Find, Compare, and rectangular paste iterate via 256 KB `ByteSource` chunks straight off the Scintilla doc, so RAM use during a multi-GB Compare is O(window) not O(file).
- **Cross-app paste from debugger / hex-tool output.** The linear and rectangular paste paths strip the address column and trailing ASCII gloss from clipboard text emitted by lldb (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA (`segment:offset`), C-string escape sequences (`\x48\x65...`), and C array literals (`{0x48, 0x65, ...}`).

#### Search & navigation

- **Find** (Cmd+F), **Find and Replace** (Cmd+Alt+F), **Find Next** (Cmd+G), **Find Previous** (Cmd+Shift+G). Single text field auto-detects ASCII vs hex byte patterns — explicit `0x` prefix or hex digits with separators (`DE AD BE EF`) trigger byte-pattern search; everything else searches as ASCII. Match-case (ASCII only) and wrap-around toggles persist across launches. Replace All wraps in one Scintilla undo group.
- **Go to Offset** (Cmd+L) accepts decimal (`1234`), hex (`0x4A2`), and relative offsets (`+0x10`, `-100`). Underscores and commas accepted as digit separators.

#### View modes

- **8/16/32/64-bit grouping** with hex or binary notation. **Big- / Little-endian display order** (only meaningful for grouping > 8-bit). Endianness affects display order only; underlying bytes are untouched.
- **Configurable address width** (4–16 digits) and **columns** (1..128/bytes-per-cell, auto-recomputed when grouping changes).
- **Display-order arrow-key navigation** in little-endian and multi-byte modes — `→` walks the displayed cell rather than the underlying byte order.

#### Compare

- **Compare HEX** opens a system Open panel and compares against any file. Differing bytes highlight in red; **Clear Compare Result** drops the highlight. Diff mask lives in memory and is rebuilt on each invocation (no `.cmp` cache file).

#### Pattern operations

- **Insert Columns** injects a hex pattern into every row at a chosen column position; the column count grows by `count`.
- **Pattern Replace** fills the current selection with a repeating hex pattern. Linear and rectangular selections both supported; the rectangular path restarts the pattern at the first byte of each row (matches Windows `eSel::HEX_SEL_BLOCK`). Both apply as one undo group.

#### Zoom

- **Cmd+Scroll or two-finger trackpad pinch** resizes the hex font in discrete steps. The pinch algorithm matches Scintilla (`ScintillaView.mm:magnifyWithEvent:`) so the gesture feels identical in the hex view and in the host's main text editor.

#### Options dialog

- **Plugins → HexEditor → Options...** carries plugin-wide preferences. Today: rectangular-selection modifier (Option vs Shift+Option), mirror-cursor toggle (rectangle vs underline). Layout designed so additional preferences can be appended without restructuring or churning the plugin menu.

#### Persistence

- **NSUserDefaults suite** `org.notepad-plus-plus.HexEditor` carries view mode, address width, columns, find options, the rect-modifier choice, the mirror toggle, and the per-buffer hex view intent across launches.

#### Localization

- **13 .strings files** covering 9 full translations and 4 regional overrides:
  - **Full:** `en` (canonical), `de` (German), `es` (Spanish), `fr` (French), `it` (Italian), `pl` (Polish), `ru` (Russian), `uk` (Ukrainian), `zh-Hans` (Simplified Chinese).
  - **Regional overrides:** `en-GB` (British English), `en-US` (American English), `es-ES` (Peninsular Spanish), `es-MX` (Mexican Spanish). Each contains only the keys that diverge from the base; everything else cascades from the base translation.
- **Cascade order.** The plugin reads `CFPreferencesCopyAppValue` for user-preferred languages (not `[NSLocale preferredLanguages]`, which the host filters against its own bundle lprojs and silently drops user-set tags). For each preference it tries the exact tag, then the base, then moves to the next preference. Last resort: embedded English defaults compiled into the dylib. The About dialog's diagnostic locale tag identifies which file the runtime is using.
- **Every format placeholder is numbered** (`%1$@`, `%1$d`, `%1$zu`, ...) — even single-arg strings — so translators learn one rule. Numbered placeholders also support deliberate repetition: French and Italian reuse `%2$@` to drive both noun pluralization and adjective agreement from the same English `s` suffix the C++ code passes in.
- **[LOCALIZATION.md](LOCALIZATION.md)** is a translator-facing guide covering the .strings file format, placeholders, the cascade, and how to test a new language locally with `defaults write org.notepadplusplus.mac AppleLanguages -array <tag>`. The About dialog links directly to it on GitHub.

#### Appearance

- Semantic `NSColor` values throughout (`unemphasizedSelectedContentBackgroundColor`, `selectedContentBackgroundColor`, `systemRedColor`, etc.) auto-flip in dark mode and follow the user's accent colour. No vertical gridlines between hex columns (cleaner, matches the visual density users expect from a hex viewer). Status row above the column headers sizes its frame from the font's `ascender - descender` so descender glyphs ('y' / 'g' / 'p') never clip.

#### About dialog

- Shows the plugin version, project URL, the diagnostic locale tag (which `.strings` file the runtime is using), and a link to LOCALIZATION.md on GitHub for users whose language isn't yet supported. The product name "Notepad++" embeds U+2060 Word Joiners between adjacent characters so it stays atomic against word-wrap (which targets the `+` boundary) and macOS hyphenation (which was breaking it after "Note").

### Divergences from Windows

The macOS port deliberately diverges from the Windows plugin in a handful of places — every divergence preserves Windows feature semantics while adopting the platform-native shape:

- **Compare HEX picks a file from disk** instead of comparing the two panes of a split-view editor. We can't replicate the Windows behaviour because Notepad++ macOS doesn't expose a plugin API for reading the contents of a second split pane. The file-picker approach has its own benefit: comparing the in-progress buffer against the saved version on disk is one step (pick the saved file), whereas on Windows it requires opening the saved file into a second split first.
- **Goto Offset** is reached via Cmd+L (matches macOS browser/Pages convention) and a context-menu entry; the host's `IDM_SEARCH_GOTOLINE` plumbing isn't intercepted yet.
- **No `Capital` preference.** Copy emits lowercase hex text (matching Windows `hexMaskNorm`); on-screen rendering is lowercase too. The macOS port doesn't expose Windows' `Capital` toggle.
- **No font / colour pickers in Options.** The host owns appearance via `NSAppearance` + Style Configurator; plugin colours are semantic and follow the host automatically.
- **Toolbar registration** isn't wired yet — the toolbar PNGs ship in the install directory ready for the host's eventual toolbar-registration API.
- **No `.cmp` cache file** for Compare results — the diff mask lives in memory (`std::vector<bool>`) and is rebuilt on each Compare invocation.
- **macOS-only context-menu additions:** Undo / Redo (the Windows version doesn't show these in its context menu) and Zoom In / Out / Restore Default Zoom. Useful on macOS where Cmd+Plus to zoom is universally expected.

### Tests

Three tiers, all green at release. See [DEVELOPER.md](DEVELOPER.md) for setup and the recommended Parallels VM workflow that runs the UI tier without locking your desktop.

- **HexCore unit tests** — pure C++, ~750 assertions covering cursor math, edit planners, clipboard format/parse helpers, view-mode mappings, byte-pattern search, byte-diff computation, and rectangle extract / format / parse paths (including the external-text inbound parser with mixed separators, raw-ASCII fallback, CRLF tolerance, and shape-mismatch rejection). Runs in milliseconds. `ctest -L unit`.
- **Plugin smoke tests** — `dlopen`s the dylib, asserts the 5 NPP exports, the `getName()` value, and the 7 menu entries with English titles. Forces `AppleLanguages = en` so the assertions stay valid on any locale. `ctest -L smoke`.
- **XCTest UI** — full suite against the running Notepad++.app: hex-toggle, undo/redo, append-at-EOF, cut/copy/paste/delete round-trips (linear and rectangular, including 1.5 GB scale), rectangle drag and extend, view-submode rendering, dialog flows for Find / Find-Replace / Goto / Address Width / Columns / Insert Columns / Pattern Replace / Compare HEX / Options, bit-precise binary editing, validation-error paths, the bookmark click, status-label glyph clipping, hex-view row-0 visibility, cursor + selection mirroring from Scintilla, mirror-cursor rendering toggle, and the localization cascade for all 13 shipped tags + an unsupported-language fallback. Driven by the `HEX_EDITOR_LANG_OVERRIDE` env var (set via `launchEnvironment`) for cascade tests, since `defaults write` from the XCUI runner is sandbox-redirected. Each run writes a Markdown summary at `macos/ui-tests-xcode/build/test-results.md`.
- **Pre-commit gate** — `macos/scripts/pre-commit-tests.sh` runs all five tiers (unit, unit+ASan/UBSan, smoke, fuzz, full UI) and is the required gate before merging to master.

### Plumbing

- **Distribution zip on every build** (`nppHexEditorPlugin-1.1.0.zip`) in the build directory's root. Contains the dylib + 13 `.strings` files + 2 toolbar icons in a flat `HexEditor/` top-level directory so unzipping into `~/.notepad++/plugins/` produces the right install layout. The zip is the artifact uploaded to a GitHub Release; not checked into the repo.
- **Toolbar icons** (`toolbar.png` light + `toolbar_dark.png` dark) ship next to the dylib + `.strings` files, ready for the host's eventual toolbar-registration API hookup.
- **`macos/scripts/install-host-plugin.sh`** is a one-command helper that copies the freshly built dylib + every shipped `.strings` file to `~/.notepad++/plugins/HexEditor/`, replacing the manual `cp dylib && cp Localizable.*.strings` compound during development.

### IDE configuration

- `.vscode/c_cpp_properties.json` uses explicit `includePath` + `defines` rather than compileCommands. CMake's universal-binary build emits `-arch arm64 -arch x86_64`, which the Microsoft C/C++ extension's IntelliSense engine cannot consume in a single AST and was silently falling back to defaults — surfacing fake "HexCore.h not found" / "no member named 'clamp'" errors in the Problems pane that never reached the actual build. The clangd extension uses `macos/.clangd` (which strips the dual-arch via its compilation-database loader), so both engines stay quiet.

---

## v1.0.0 — premature tag (not distributed)

A pre-release tag from before Notepad++ macOS exposed plugin-manager
distribution. v1.0.0 was never installed by users; it exists only in
the git history. v1.1.0 above is the debut public release.

---

## macOS port — engineering notes

The macOS port is a from-scratch native plugin. Source lives in [macos/](macos/) and does not share build artifacts, headers, or runtime code with the Windows tree.

### Platform & build

| | Windows baseline | macOS port |
| --- | --- | --- |
| Binary | `HexEditor.dll` | `HexEditor.dylib` |
| UI toolkit | Win32 / custom-drawn `DockableDlg` | AppKit (`NSTableView` overlay) |
| Plugin ABI header | `PluginInterface.h` | `NppPluginInterfaceMac.h` |
| Build system | MSVC solution under [HexEditor/projects/2003/](HexEditor/projects/2003/) | CMake ≥ 3.20, see [macos/CMakeLists.txt](macos/CMakeLists.txt) |
| Architectures | x86, x64, arm64 (Windows) | x86_64 + arm64 universal, or `-DCMAKE_OSX_ARCHITECTURES=arm64` only |
| Install path | Notepad++ `plugins\HexEditor\` | `~/.notepad++/plugins/HexEditor/HexEditor.dylib` via `cmake --install` |
| Localization | `lang/NativeLang_*.ini` (German + template) | 13 `.strings` files (9 full translations + 4 regional overrides) at `macos/resources/Localizable.<tag>.strings` |
| Persistent settings | `HexEditor.ini` (colors, fonts, columns, address width, autostart, etc.) | NSUserDefaults suite `org.notepad-plus-plus.HexEditor` (view mode, address width, columns, find options, rect modifier, mirror toggle, per-buffer hex view intent) |

### Source layout

The Windows source totals roughly 8,400 LOC across [HexEditor/src/](HexEditor/src/), with the bulk in [HEXDialog.cpp](HexEditor/src/HEXDialog.cpp) (~4,667 LOC) and [Hex.cpp](HexEditor/src/Hex.cpp) (~1,667 LOC), plus subdialog directories `HelpDlg/`, `OptionDlg/`, `UserDlg/`, and `misc/` Win32 helpers.

The macOS source is roughly 2,366 LOC split into:

- [macos/src/HexEditor.mm](macos/src/HexEditor.mm) — AppKit/Notepad++ adapter (~1,976 LOC)
- [macos/src/core/HexCore.h](macos/src/core/HexCore.h) and [macos/src/core/HexCore.cpp](macos/src/core/HexCore.cpp) — platform-neutral planning logic (~390 LOC), shared between the plugin and the unit-test executable

The split is new: HexCore exposes pure planning functions (`planHexDigitEdit`, `planAsciiByteEdit`, cursor movement, dump formatting) that return a `ByteEditOperation { offset, replacedByteCount, replacement, nextCursor }`. The adapter layer is the only code that touches Scintilla and applies each operation inside a single undo group. The Windows plugin had no equivalent boundary — editing logic and the dialog window were intertwined in `HEXDialog.cpp`.

### Plugin menu commands

The macOS port has 7 menu entries (Windows separates several with menu separators, which macOS plugins can't emit; the macOS sequence is the same items minus the visual separators).

| # | Windows | macOS | Status |
| --- | --- | --- | --- |
| 0 | View in HEX | View in HEX | Implemented (with shortcut binding via `_pShKey`) |
| 1 | Compare HEX | Compare HEX | Implemented (compares against a file rather than Windows' second split view) |
| 2 | Clear Compare Result | Clear Compare Result | Implemented |
| 3 | Insert Columns... | Insert Columns... | Implemented |
| 4 | Pattern Replace... | Pattern Replace... | Implemented for both linear and rectangular selections; per-row pattern restart matches Windows `eSel::HEX_SEL_BLOCK` |
| 5 | Options... | Options... | Implemented (rect-modifier and mirror-cursor preferences) |
| 6 | Help... | Help... | macOS Help is a simple About dialog, not the Windows [HelpDlg](HexEditor/src/HelpDlg/) URL-control window |

The Windows plugin separately exposes Find / Replace / Goto from inside the docked HEX dialog rather than the plugin menu; those entry points have no macOS equivalent yet (see "Not yet ported" below).

Menu wiring on Windows is in [Hex.cpp:100-117](HexEditor/src/Hex.cpp#L100-L117); on macOS in [HexEditor.mm:1885-1923](macos/src/HexEditor.mm#L1885-L1923). Stub bodies are at [HexEditor.mm:1851-1879](macos/src/HexEditor.mm#L1851-L1879).

### Editor capabilities

**Implemented on macOS:**

- Inline overlay that swaps the active Scintilla view for an `NSTableView`-based hex grid (offset / hex bytes / ASCII columns)
- Direct byte overwrite from both hex and ASCII columns; append at EOF
- Range selection across hex and ASCII panes
- Context-menu and host **Edit** menu Cut / Copy / Paste / Delete with Windows-faithful clipboard semantics:
  - **Copy** from the hex pane writes lowercase space-separated hex text (`"de ad be ef"`) and also publishes the raw bytes under `public.data` so paste *within* the hex view round-trips losslessly.
  - **Copy** from the ASCII pane writes the bytes as a UTF-8 string.
  - **Cut Binary Content** / **Copy Binary Content** / **Paste Binary Content** always operate on raw bytes (matches the Windows menu).
  - **Paste** auto-detects: tries `public.data` → parses pasteboard text as hex (`"DE AD"`, `"deadbeef"`, `"0xDE,0xAD"` all accepted) → falls back to the text's UTF-8 bytes.
- Select All routes from the host Edit menu / Cmd+A through the responder chain
- Cmd-Z / Cmd-Shift-Z undo and redo, applied as Scintilla undo groups
- Cmd+Home / Cmd+End cursor jumps to document start/end (bare `End` only goes to row end — see [TESTING.md:127-129](macos/TESTING.md#L127-L129))
- Bookmark toggling via offset-column click (the bookmark row highlight survives in the offset gutter)
- View submode submenu (Windows-faithful "View in" entry) — switch grouping between **8-Bit**, **16-Bit**, **32-Bit**, **64-Bit**; toggle between **hex** and **binary** notation; toggle **Big Endian / Little Endian** display order (only meaningful for grouping > 8-bit). Auto-recomputes cells per row as `16 / bytesPerCell`, mirroring Windows. Endianness affects display order only; underlying bytes are untouched.
- **Address Width...** and **Columns...** dialogs in the context menu, faithful to Windows [HEXDialog.cpp:2027-2089](HexEditor/src/HEXDialog.cpp#L2027-L2089). Address Width accepts 4–16 digits, Columns accepts 1..(128/bytesPerCell). Implemented as native `NSAlert`s with a numeric accessory field rather than the Win32 modal dialog template — the macOS-idiomatic shape (per the project's "look like a Mac UI" call) — but the validation ranges and error wording mirror Windows.
- **Go to Offset…** in the context menu (also bound to **Cmd+L** in the hex view, matching the macOS browser/Pages convention for jump-to-location). Single-field NSAlert that auto-detects format: decimal (`1234`), hex (`0x4A2`), or relative (`+0x10`, `-100`). Underscores and commas are accepted as digit separators. Mirrors the Windows [GotoDialog.cpp](HexEditor/src/UserDlg/GotoDialog.cpp) feature without porting the Win32 multi-mode UI; the parser lives in `HexCore::resolveGotoOffset`. Windows wires Goto via the host's `IDM_SEARCH_GOTOLINE` ([Hex.cpp:818](HexEditor/src/Hex.cpp#L818)); on macOS that requires intercepting host menu commands — deferred — so for now the entry point is the context menu plus the keybinding.
- **Find…** (Cmd+F) / **Find and Replace…** (Cmd+Alt+F) / **Find Next** (Cmd+G) / **Find Previous** (Cmd+Shift+G), all in the context menu and the hex view's `performKeyEquivalent:` (overriding the host's Edit menu so our Find handles the shortcut when the hex view has focus). Single text field auto-detects ASCII vs hex bytes — explicit `0x` prefix or hex digits with separators (`DE AD BE EF`) trigger byte-pattern search; everything else searches as ASCII. Match-case (ASCII only) and wrap-around toggles persist across launches via the existing `org.notepad-plus-plus.HexEditor` prefs suite. Replace All applies all replacements inside one Scintilla undo group, so a single Cmd+Z reverts the whole sweep. The pure search engine lives in `HexCore::findBytePattern` + `parseSearchPattern` — covered by 14 new unit assertions including hex/ASCII auto-detect, forward/backward, wrap edges, and case-insensitive matching. Windows hosts a 819-LOC Win32 dialog with transparency, multi-type combo with history, in-selection scoping, and several coding modes ([UserDlg/FindReplaceDialog.cpp](HexEditor/src/UserDlg/FindReplaceDialog.cpp)) — those layers are intentionally not ported in favour of the macOS-idiomatic single dialog.
- **Insert Columns…** in the plugin menu — three-field NSAlert (pattern, count, position) inserts a hex pattern into every row at a chosen column position and grows the column count to match. Mirrors Windows [PatternDialog.cpp:139](HexEditor/src/UserDlg/PatternDialog.cpp#L139) `onInsert`: pattern bytes cycle to fill `count × bytesPerCell` bytes per row; the entire sweep is one Scintilla undo group (single Cmd+Z reverts the whole insertion); validation matches Windows ranges (count ≤ 128/bpc − currentColumns; position ∈ [0, currentColumns]). Hex view must be active; otherwise the menu item shows a directive instead of silently failing.
- **Compare HEX** + **Clear Compare Result** in the plugin menu. Compare opens an `NSOpenPanel`, reads the chosen file, and highlights every byte cell in the current hex view whose underlying byte differs from the file (or sits beyond the shorter buffer's end). The diff math lives in `HexCore::computeByteDiffs`. Mirrors Windows [Hex.cpp:1473](HexEditor/src/Hex.cpp#L1473) `DoCompare` semantics — bytes-only-on-one-side count as differing — but skips the Win32 `.cmp` cache file and the two-Scintilla-handle dance in favour of a single `std::vector<bool>` mask that the cell renderer consults in `willDisplayCell:`. **Divergence from Windows:** Windows compares the two panes of Notepad++'s split-view editor; the macOS port asks the user to pick a file from disk. We can't replicate the Windows behavior because Notepad++ macOS doesn't yet expose a plugin API for reading the contents of a second split pane. The file-picker approach has its own benefit: comparing the in-progress buffer against the saved version on disk is one step (pick the saved file), whereas on Windows it requires opening the saved file into a second split first. Test hook `--test-compare-with=<path>` lets the XCTest harness drive Compare without trying to automate `NSOpenPanel`.
- **Pattern Replace…** in the plugin menu — single-field NSAlert that fills the current hex selection with a repeating hex pattern. Mirrors Windows [PatternDialog.cpp:249](HexEditor/src/UserDlg/PatternDialog.cpp#L249) `onReplace` for both the `eSel::HEX_SEL_NORM` (linear) and `eSel::HEX_SEL_BLOCK` (rectangular) cases. Pattern bytes cycle to fill the entire selection length (e.g. linear selection of 4 bytes + pattern `AB CD` → `AB CD AB CD`); the rectangular path restarts the pattern at the first byte of each row, matching Windows. The whole replacement is a single Scintilla undo group. Refuses to operate without a selection or hex view, surfacing a clear directive in either case.
- All view-mode and gutter settings persist across launches via an `NSUserDefaults` suite at `org.notepad-plus-plus.HexEditor`. Keys: `bytesPerCell`, `notationBinary`, `littleEndian`, `addressWidth`, `columns`. Loaded in `setInfo`, saved on every change.
- Four accessibility identifiers exposed for UI test reach (`hex-editor.root`, `hex-editor.table`, `hex-editor.status`, `hex-editor.dialog.input`)

**Context menu — current shape:**

```text
Undo / Redo
─────────
Cut / Copy / Paste / Delete
─────────
Cut Binary Content / Copy Binary Content / Paste Binary Content
─────────
View in ▶  8-Bit / 16-Bit / 32-Bit / 64-Bit
           ─────────
           to Hex / to Binary
           to BigEndian / to LittleEndian   (hidden when 8-Bit)
─────────
Zoom In / Zoom Out / Restore Default Zoom
```

Diverges from Windows in two intentional ways: Undo/Redo and Zoom In/Out/Restore are macOS additions kept for usability; Select All and Toggle Bookmark are not duplicated in the context menu (Select All is reachable via the host Edit menu / Cmd+A; bookmarks toggle via clicking the offset column). Address Width and Columns are reachable via the context menu and are NSUserDefaults-backed.

**View submode capabilities:**

- **Bit-precise editing in binary notation.** Typing `0` or `1` while in Binary view edits a single bit at the caret (MSB-first within the byte) and advances by one bit. The cursor's `nibble` field is overloaded to carry a bit index 0..7 in Binary mode (vs 0..1 in Hex mode); `clampCursor` got a `ViewMode`-aware overload to clamp to the right range when modes switch. Implemented in `HexCore::planBitEdit`.
- **Display-order arrow-key navigation in multi-byte / little-endian modes.** `navigateLeft` / `navigateRight` now have `ViewMode`-aware overloads that walk display digits left-to-right rather than walking the underlying byte array. In little-endian 16-bit mode, pressing → from byte 0 nibble 1 now correctly advances to byte 3 nibble 0 (cell 1's first displayed byte) instead of byte 1 nibble 0. Click and caret rendering were already display-order-correct.

**Deliberate omissions** (present in [HexEditor/src/](HexEditor/src/), intentionally not ported because the macOS host owns the responsibility or the Mac surface differs):

- Color / font configuration in Options ([OptionDlg/OptionDialog.cpp](HexEditor/src/OptionDlg/OptionDialog.cpp)). The macOS Options dialog ships, but its scope is plugin-specific behaviour (rect modifier, mirror toggle); appearance is delegated to `NSAppearance` + the host's Style Configurator.
- Custom font (bold / italic / underline / capital), color theming, current-line highlight — same delegation reason.
- Dark mode plumbing — dark mode works on macOS automatically via semantic `NSColor` values, so the explicit Win32 dark-mode logic added to the Windows plugin in v0.9.14 has no macOS counterpart.
- Help dialog with embedded URL controls ([HelpDlg/](HexEditor/src/HelpDlg/)). The macOS Help is a simple About dialog with the project URL + localization-guide URL — the Win32 URL-control-windowing layer doesn't translate.

**Not yet wired** (host or plugin work outstanding):

- Toolbar icon registration. The PNGs ship in the install directory; the host's toolbar-registration plugin API isn't exposed yet.
- Autostart-by-extension and autostart-by-file-percentage (`AUTOSTART_MAX`). Requires a way to intercept buffer-load notifications.
- UTF-8 / UTF-16 conversion ([Utf8_16.cpp](HexEditor/src/Utf8_16.cpp)). The Windows plugin ships a converter for non-UTF-8 source files; the macOS port treats the buffer as raw bytes.

### Testing infrastructure

The Windows tree ships with **no automated tests** — no `tests/` directory, no test fixtures, no CI test job (only build CI in [appveyor.yml](appveyor.yml) and the GitHub Actions workflow). Everything that exists below is new for the macOS port.

**Tier 1 — pure C++ unit tests** ([macos/tests/HexCoreTests.cpp](macos/tests/HexCoreTests.cpp))

Links the same `HexCore.cpp` the plugin links. Runs as the `HexEditorCoreTests` CTest target with label `unit`:

```sh
ctest --test-dir macos/build-universal -L unit --output-on-failure
```

Currently covers `hexDigitValue`, `isVisibleEditableOffset`, cursor movement (`clampCursor`, `moveCursor`, `cursorToLineStart/End`, `cursorToDocumentStart/End`, `navigateLeft`, `navigateRight`), `selectedOrCurrentRange`, `planHexDigitEdit`, `planAsciiByteEdit`, and `makeHexDump`. Uses an in-tree `HEX_EXPECT` / `HEX_EXPECT_EQ` runner — no third-party framework dependency.

**Tier 2 — plugin smoke tests** ([macos/tests/HexPluginSmokeTests.cpp](macos/tests/HexPluginSmokeTests.cpp))

`dlopen`s the built `HexEditor.dylib` and verifies the Notepad++ host contract without launching the editor. Runs as `HexEditorPluginSmokeTests` with label `smoke` (~25 assertions, completes in milliseconds):

```sh
ctest --test-dir macos/build-universal -L smoke --output-on-failure
```

Asserts that `setInfo`, `getName`, `getFuncsArray`, `beNotified`, and `messageProc` resolve via `dlsym`; that `getName()` returns `"HexEditor"`; that `getFuncsArray` reports 8 menu entries with the expected titles and non-NULL callbacks. `setInfo` is called with a zeroed `NppData` first because the plugin populates `funcItem[]` inside that handler.

**Tier 3 — XCTest UI tests** ([macos/ui-tests-xcode/](macos/ui-tests-xcode/))

Host-level UI automation against the Notepad++ macOS app with the plugin installed. Built as an XcodeGen-generated `.xcodeproj` (spec at [project.yml](macos/ui-tests-xcode/project.yml), generated project gitignored) plus a minimal `TestRunner` stub host required by macOS UI test bundles — SwiftPM XCTest packages cannot host `XCUIApplication`. Runs via:

```sh
macos/ui-tests-xcode/run-tests.sh
# or via CTest:
ctest --test-dir macos/build-universal -L xctest --output-on-failure
```

Set `NPP_MACOS_APP=/path/to/Notepad++.app` to override the default host app path.

Test cases in [HexEditorUITests.swift](macos/ui-tests-xcode/Tests/HexEditorUITests.swift):

- `testHostApplicationLaunches` — `XCUIApplication(url:)` launches and foregrounds Notepad++ macOS
- `testHexEditorPluginMenuIsPresent` — the `HexEditor` submenu appears under `Plugins`
- `testViewInHexToggle` — toggles the hex overlay on and off, asserting the table appears and disappears
- `testStatusLabelReportsByteCount` — seeded buffer's byte count is reported in the status label
- `testEditMenuActionsRouteToHexOverlay` — Cut/Copy/Paste/Delete/Select All in the host Edit menu are all enabled when the hex overlay has focus (responder chain integration)
- `testEditMenuCopyFromHexView` — Edit > Select All + Edit > Copy round-trips through the system pasteboard
- `testHexByteAppendUndoRedo` — appends a hex digit at EOF; asserts byte count grows, Cmd+Z reverts, Cmd+Shift+Z restores
- `testHexCutAndUndo` — Edit > Select All + Edit > Cut empties buffer; Cmd+Z restores; Cmd+Shift+Z re-cuts
- `testHexPasteAtCmdEnd` — Cmd+End jumps to EOF, then Edit > Paste grows the buffer from clipboard
- `testContextMenuCommands` — right-clicking exposes Undo/Redo/Cut/Copy/Paste/Delete/Select All/Toggle Bookmark/Copy HEX Dump

**Harness quirks discovered while building the UI tier** (documented in [TESTING.md:119-129](macos/TESTING.md#L119-L129)):

1. `XCUIApplication.launchArguments = ["-nosession"]` is required — otherwise session restore loads `~/.notepad++/session.plist` and tests run against unpredictable buffer content.
2. `XCUIApplication.typeText(_:)` is silently dropped by Scintilla in this sandbox+runner combo. Buffer seeding goes through `NSPasteboard.general` + Edit > Paste via the menu bar instead.
3. `typeText` *does* work once the hex overlay is first responder — so plugin-side hex-digit input uses it directly.
4. A one-second settle is needed after toggling into hex view, otherwise the host's Edit menu validation can race against responder propagation and report items disabled.
5. Bare `End` only reaches end-of-row; document-end navigation requires `Cmd+End`, which the plugin special-cases in `HexTableView.keyDown`. Without this, append-at-EOF tests would be capped at ≤16-byte buffers.

**Manual checklist** for behavior that resists automation (responder routing, multi-buffer flows): see [TESTING.md:65-79](macos/TESTING.md#L65-L79).

### License

Unchanged. Both the Windows plugin and the macOS port carry the original GPLv2 header from Jens Lorenz's 2006 source (see [HexEditor/src/Hex.h:1-16](HexEditor/src/Hex.h#L1-L16)).
