# Changelog

This file lists what's changed in the macOS port of the HEX-Editor plugin. The
original Windows version, kept untouched in [HexEditor/](HexEditor/), has its
own history in [HexEditor/change.log](HexEditor/change.log).

## v1.1.0 — rectangular (block) selection

Adds full rectangular selection support — the macOS port now matches the
Windows plugin's `eSel::HEX_SEL_BLOCK` capability (the one divergence v1.0.0
called out as not yet ported). Also brings back the Options menu, this time
with real settings, and converts every multi-parameter localized string to
numbered positional syntax so translators can reorder freely.

### What's new

- **Rectangular drag** — Option-drag inside the hex byte pane or ASCII pane draws a 2D rectangle (cell-granular). Option-drag in the address column drags whole rows (full bytes-per-row width). The modifier is configurable in the new Options dialog (Option, matching Scintilla / Windows; or Shift+Option, matching VS Code).
- **Keyboard extension** — Shift+Option+arrow keys grow / shrink the rectangle from the dragged-to corner; the first such press while no rect is active bootstraps a 1×1 rect at the caret. Plain arrow / Home / End / typing any character collapses the rect (typing replaces it with normal byte editing at the cursor).
- **Cut / Copy / Paste / Delete on a rectangle** — Copy emits both a public-text fallback (hex per row, or ASCII per row, or address strings, joined by `\n` depending on the source pane) and a custom pasteboard type `org.notepad-plus-plus.HexEditor.rectangular` carrying a `kind` tag (Bytes / Ascii / Addresses) plus the rectangle's shape. Round-tripping through the plugin's clipboard preserves geometry. Delete is zero-fill (file size unchanged, offsets preserved).
- **Strict-shape paste** — Pasting a rectangular payload requires the destination to be a rectangle of the exact same width × height. Mismatches show a clarifying dialog naming the required dimensions. Address-source clipboards are rejected with "cannot paste as bytes" since they're meta about the data, not the data itself. External text-only clipboards (no custom UTI) are parsed as `\n`-separated rows per the same rules; single-line text falls through to the existing linear paste path so cross-app copy/paste behaves as before.
- **Pattern Replace on a rectangle** fills row-by-row with the pattern restarting at each row's first byte — matches the Windows `eSel::HEX_SEL_BLOCK` semantics. Dialog wording forks: the rect path explains the per-row restart so the user knows it won't run continuously across rows.
- **Options dialog** (Plugins → HEX-Editor → Options...) — the menu entry removed in 0457695 returns, now backing real settings rather than a stub. Today's only entry is the rectangular-selection modifier; the layout is built so additional preferences can be appended without restructuring or churning the plugin menu.
- **Numbered localized parameters** — every `.strings` key with two or more format placeholders now uses numbered positional syntax (`%1$d`, `%2$@`, ...) so translators can swap parameter order. The dynamic-width address formatting in `goto.message` was refactored at the call site to pre-format the hex strings, leaving translators with simple `%1$@` / `%2$@` slots they don't need printf knowledge to translate.
- **Cross-app paste from debugger / hex-tool output** — the linear and rectangular paste paths now strip the address column and trailing ASCII gloss from clipboard text emitted by lldb (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA (`segment:offset`), C-string escape sequences (`\x48\x65...`), and C array literals (`{0x48, 0x65, ...}`). Pre-fix the linear parser silently parsed the address bytes as part of the data — anyone who tried `Cmd+V` from `lldb` got `0x10 0x00 0x00 ...` prepended to their buffer without an error. Now the data lands cleanly.
- **Copy emits xxd-style hex dump text** (linear + rectangular). The user mental model is "Copy Binary Content = raw bytes, regular Copy = text representation of what you see" — and the on-screen text representation is the address + hex bytes + ASCII gloss. So `Cmd+A` → `Cmd+C` → paste into a Markdown / README / crash report / GitHub issue gets you the hex dump as text that round-trips back into the plugin via the inbound parser. v1.0.0 emitted the bare `48 65 6c 6c 6f` hex string which was useless as documentation; for that legacy use case (`Python bytes.fromhex`, `xxd -r -p`, etc.), use `Copy Binary Content` and have the receiving tool work directly with the bytes, or paste the hex dump into a tool that strips addresses (which now includes us). Rect copy follows the same shape — multi-line hex dump scoped to the rect's columns. Custom-UTI paste-back into the plugin still uses the binary payload for shape-perfect round-trip; only the public-text fallback changed.

### v1.1.0 test additions

- **HexCore** added 4 new suites: `extractRectBytes`, `formatRectClipboardHex`, `formatRectClipboardAscii`, and `parseRectClipboardText` (which exercises the external-text inbound parser — `\n`-separated hex with mixed separators, raw-ASCII fallback when any line fails as hex, CRLF tolerance, shape-mismatch rejection, empty/blank rejection). 30 suites total, all green.
- **Smoke** updated for the 7-item menu (View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Options, Help).
- **UI** — diagnostic AX value extended with rect fields (`rectActive`, `rectOrigin`, `rectWidth`, `rectHeight`, `rectBpr`, `rectOriginPane`) so future tests can verify rect state structurally rather than via fragile drag mechanics. The Swift `HexCursorState` parser was updated in lock-step. New test: Options dialog opens and cancels cleanly.

### Updates to v1.0.0 divergences

- ~~"Pattern Replace operates on the linear selection only — the rectangular `eSel::HEX_SEL_BLOCK` branch isn't ported"~~ — **resolved in v1.1.0**: rectangular Pattern Replace is now supported with per-row pattern restart matching the Windows semantics.
- ~~"No Options dialog"~~ — partly resolved: the dialog is back, but for plugin-specific behavior (rect modifier) rather than appearance. Color / font choices remain delegated to the host's `NSAppearance` + Style Configurator.

### IDE configuration

- `.vscode/c_cpp_properties.json` — switched the Microsoft C/C++ extension from compileCommands to explicit `includePath` + `defines`. CMake's universal-binary build emits `-arch arm64 -arch x86_64`, which the extension's IntelliSense engine cannot consume in a single AST and was silently falling back to defaults — surfacing fake "HexCore.h not found" / "no member named 'clamp'" errors in the Problems pane that never reached the actual build. The clangd extension continues to use `macos/.clangd` (which already strips the dual-arch via its compilation-database loader), so both engines are now quiet.

---

## v1.0.0 — first macOS release

The first public release of the macOS port. It runs as a plugin (`HexEditor.dylib`)
inside [Notepad++ macOS](https://github.com/notepad-plus-plus-macos) and matches
every entry on the Windows plugin's menu: View in HEX, Compare HEX, Clear
Compare Result, Insert Columns, Pattern Replace, and Help. It ships with English
(`en`, `en-GB`, `en-US`) and German (`de`) text, follows the host's dark/light
mode, and supports two-finger trackpad pinch to zoom (the same gesture that
already works in the host's text view).

### What works

- **Hex view** — inline `NSTableView` overlay swaps the active Scintilla view for an offset / hex bytes / ASCII grid with direct overwrite + append editing, range selection across both panes, bookmark toggling on the offset gutter, and Cmd+Home / Cmd+End navigation to document edges. The hex view mirrors the Scintilla caret position when toggled — open it with the cursor anywhere in the source buffer and the hex view scrolls to the corresponding byte; selections are mirrored too, with the hex caret landing at the end of the selected range.
- **Clipboard** — Cut / Copy / Paste / Delete with Windows-faithful semantics (Copy emits lowercase `de ad be ef` text, Copy Binary emits raw bytes; Paste auto-detects). Edit menu integration via responder-chain routing.
- **View modes** — 8/16/32/64-bit grouping, hex / binary notation, big / little-endian display, configurable address width (4–16 digits) and columns (1..128/bpc). Bit-precise editing in binary notation. Display-order arrow-key navigation in little-endian and multi-byte modes. All settings persist via `NSUserDefaults` suite `org.notepad-plus-plus.HexEditor`.
- **Zoom** — Cmd+Scroll or two-finger trackpad pinch resizes the hex font in discrete steps. The pinch algorithm matches Scintilla's (`ScintillaView.mm:magnifyWithEvent:`) so the gesture feels identical in the hex view and in the host's main text editor.
- **Search** — Find (Cmd+F), Find and Replace (Cmd+Alt+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G). Auto-detects ASCII vs hex byte patterns; match-case (ASCII only) and wrap-around toggles persist. Replace All wraps in a single Scintilla undo group.
- **Navigation** — Go to Offset (Cmd+L) accepts decimal, `0x`-prefixed hex, and relative `+`/`-` offsets with underscore / comma separators.
- **Compare** — pick any file via the system Open panel; differing bytes highlight in red; Clear Compare Result drops the mask.
- **Pattern editing** — Insert Columns (inject a repeating hex pattern into every row at a chosen column position) and Pattern Replace (fill a selection with a repeating pattern). Both apply as one undo group.
- **Localization** — Four shipped strings files: full translations for English (`Localizable.en.strings`, the canonical / US-spelling source) and German (`Localizable.de.strings`); regional override files for British English (`Localizable.en-GB.strings`) and American English (`Localizable.en-US.strings`) demonstrate the cascade pattern (override files contain only the keys that diverge from the base; everything else cascades from the base translation, then from embedded English defaults). Diagnostic line in the About dialog identifies which language file the runtime is using. Selection reads `CFPreferencesCopyAppValue` rather than `[NSLocale preferredLanguages]` so user-set tags aren't filtered against the host's bundle lprojs.
- **Appearance** — semantic `NSColor` values (`unemphasizedSelectedContentBackgroundColor`, `selectedContentBackgroundColor`, `systemRedColor`) auto-flip in dark mode and follow the user's accent colour. No vertical gridlines between hex columns (cleaner, matches the visual density users expect from a hex viewer). Status row above the column headers sizes its frame from the font's `ascender - descender` so descender glyphs ('y' / 'g' / 'p') never clip. The plugin inherits the host's font and theme; there is no Options dialog (the host owns appearance).

### Tests

Three tiers, all green at release. See [DEVELOPER.md](DEVELOPER.md) for setup and the
recommended Parallels VM workflow that runs the UI tier without locking your desktop.

- **HexCore unit tests** — pure C++, ~700 assertions covering cursor math, edit planners, clipboard format/parse helpers, view-mode mappings, byte-pattern search, byte-diff computation, and localization-independent logic. Runs in milliseconds. `ctest -L unit`.
- **Plugin smoke** — `dlopen`s the dylib, asserts the 5 NPP exports, the `getName()` value, and the `funcItem` entries with English titles. Forces `AppleLanguages = en` so the assertions stay valid on any locale. `ctest -L smoke`.
- **XCTest UI** — 37 cases against the running Notepad++.app: hex-toggle, undo/redo, append-at-EOF, cut/copy/paste round-trips, view-submode rendering, dialog flows for Find / Find-Replace / Goto / Address Width / Columns / Insert Columns / Pattern Replace / Compare HEX, bit-precise binary editing, validation-error paths, the bookmark click, status-label glyph clipping, hex-view row-0 visibility, cursor + selection mirroring from Scintilla, and the localization cascade for en, en-GB, en-US, de, and unsupported tags. Driven by the `HEX_EDITOR_LANG_OVERRIDE` env var (set via `launchEnvironment`) for cascade tests, since `defaults write` from the XCUI runner is sandbox-redirected. Each run writes a Markdown summary at `macos/ui-tests-xcode/build/test-results.md`. `macos/ui-tests-xcode/run-tests.sh`.

### Documented divergences from Windows

The macOS port deliberately diverges from the Windows plugin in a handful of places — every divergence preserves Windows feature semantics while adopting the platform-native shape:

- **No Options dialog** — Windows manages bold/italic/underline + RGB pickers in `Hex.cpp`; the macOS host owns appearance via `NSAppearance` + the host's Style Configurator. Plugin colours are semantic and follow the host automatically.
- **Compare HEX picks a file from disk** instead of comparing the two panes of a split-view editor. On Windows, Notepad++ can split the editor in two and the plugin compares the active pane against the other pane. We can't do that on macOS yet because Notepad++ macOS doesn't expose a plugin API for reading the contents of a second split pane. So instead, the macOS port pops up an Open panel and compares against whatever file you pick. As a side benefit, this makes "compare my unsaved edits against the version on disk" a one-step workflow — you just pick the saved file. On Windows, you'd have to first open the saved file in a second split, then run Compare.
- **Pattern Replace operates on the linear selection only** — the rectangular `eSel::HEX_SEL_BLOCK` branch isn't ported because the macOS hex view has only the linear selection model.
- **Goto offset** is reached via Cmd+L in the hex view (matches macOS browser/Pages convention) and a context-menu entry; the host's `IDM_SEARCH_GOTOLINE` plumbing isn't intercepted yet.
- **No `.cmp` cache file** for Compare results — the diff mask lives in memory (`std::vector<bool>`) and is rebuilt on each Compare invocation.
- **Copy emits lowercase hex text** by default (matching Windows `hexMaskNorm`); on-screen rendering also lowercase (matching Windows default unless the `Capital` pref is set). The macOS port has no `Capital` pref.
- **macOS-only context-menu additions**: Undo / Redo (the Windows version doesn't show these in its context menu) and Zoom In/Out/Restore. These are useful on macOS where typing `Cmd-Plus` to zoom is universally expected.

### Internal port mechanics

The body below documents the per-pass dev work — kept for future translators, contributors, and anyone wanting the *why* behind a specific divergence.

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
| Localization | `lang/NativeLang_*.ini` (German + template) | None yet (English-only strings hardcoded) |
| Persistent settings | `HexEditor.ini` (colors, fonts, columns, address width, autostart, etc.) | None — no preferences are persisted |

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
| 4 | Pattern Replace... | Pattern Replace... | Implemented for both linear and rectangular selections (v1.1.0 added the rect path; per-row pattern restart matches Windows `eSel::HEX_SEL_BLOCK`) |
| 5 | Options... | Options... | Real dialog as of v1.1.0 (rect-modifier preference); was a stub from v1.0.0 |
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
- **Pattern Replace…** in the plugin menu — single-field NSAlert that fills the current hex selection with a repeating hex pattern. Mirrors Windows [PatternDialog.cpp:249](HexEditor/src/UserDlg/PatternDialog.cpp#L249) `onReplace` for the `eSel::HEX_SEL_NORM` case (linear selection); the Win32 `eSel::HEX_SEL_BLOCK` rectangular-selection branch isn't ported because the macOS hex view has only the linear selection model. Pattern bytes cycle to fill the entire selection length (e.g. selection of 4 bytes + pattern `AB CD` → `AB CD AB CD`); the whole replacement is a single Scintilla undo group. Refuses to operate without a selection or hex view, surfacing a clear directive in either case.
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

Diverges from Windows in two intentional ways: Undo/Redo and Zoom In/Out/Restore are macOS additions kept for usability; Select All and Toggle Bookmark are not duplicated in the context menu (Select All is reachable via the host Edit menu / Cmd+A; bookmarks toggle via clicking the offset column). The Windows "Address Width..." / "Columns..." entries are still pending; they require an `NSUserDefaults`-backed prefs store and the corresponding Cocoa input dialogs — tracked under "Not yet ported".

**View submode — earlier follow-ups now landed:**

- **Bit-precise editing in binary notation.** Typing `0` or `1` while in Binary view edits a single bit at the caret (MSB-first within the byte) and advances by one bit. The cursor's `nibble` field is overloaded to carry a bit index 0..7 in Binary mode (vs 0..1 in Hex mode); `clampCursor` got a `ViewMode`-aware overload to clamp to the right range when modes switch. Implemented in `HexCore::planBitEdit`.
- **Display-order arrow-key navigation in multi-byte / little-endian modes.** `navigateLeft` / `navigateRight` now have `ViewMode`-aware overloads that walk display digits left-to-right rather than walking the underlying byte array. In little-endian 16-bit mode, pressing → from byte 0 nibble 1 now correctly advances to byte 3 nibble 0 (cell 1's first displayed byte) instead of byte 1 nibble 0. Click and caret rendering were already display-order-correct.

**Not yet ported from Windows** (present in [HexEditor/src/](HexEditor/src/), absent on macOS):

- Options dialog with color/font configuration ([OptionDlg/OptionDialog.cpp](HexEditor/src/OptionDlg/OptionDialog.cpp))
- Help dialog with embedded URL controls ([HelpDlg/](HexEditor/src/HelpDlg/))
- Custom font (bold / italic / underline / capital), color theming, current-line highlight
- Dark mode support (added on Windows in v0.9.14)
- Autostart-by-extension and autostart-by-file-percentage (`AUTOSTART_MAX`)
- UTF-8 / UTF-16 conversion ([Utf8_16.cpp](HexEditor/src/Utf8_16.cpp))
- Toolbar icon registration

The macOS About copy advertises only the implemented set; see [HexEditor.mm:1846-1849](macos/src/HexEditor.mm#L1846-L1849).

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

Asserts that `setInfo`, `getName`, `getFuncsArray`, `beNotified`, and `messageProc` resolve via `dlsym`; that `getName()` returns `"HEX-Editor"`; that `getFuncsArray` reports 8 menu entries with the expected titles and non-NULL callbacks. `setInfo` is called with a zeroed `NppData` first because the plugin populates `funcItem[]` inside that handler.

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
- `testHexEditorPluginMenuIsPresent` — the `HEX-Editor` submenu appears under `Plugins`
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
