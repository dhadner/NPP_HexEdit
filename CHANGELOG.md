# Changelog

This file tracks the macOS port of the HEX-Editor plugin against the original Windows baseline preserved in [HexEditor/](HexEditor/). The Windows plugin's own historical change log lives at [HexEditor/change.log](HexEditor/change.log) and is unchanged by the porting work.

## macOS port — in progress

The macOS port is a from-scratch native plugin. Source lives in [macos/](macos/) and does not share build artifacts, headers, or runtime code with the Windows tree.

### Platform & build

| | Windows baseline | macOS port |
|---|---|---|
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

| # | Windows | macOS | Status |
|---|---|---|---|
| 0 | View in HEX | View in HEX | Implemented (with shortcut binding via `_pShKey`) |
| 1 | Compare HEX | Compare HEX | **Stub** — shows "not ported" dialog |
| 2 | Clear Compare Result | Clear Compare Result | **Stub** |
| 3 | *(separator)* | Insert Columns... | macOS has no menu separators; commands renumbered |
| 4 | Insert Columns... | Pattern Replace... | **Stub** on macOS |
| 5 | Pattern Replace... | Options... | **Stub** on macOS |
| 6 | *(separator)* | **Copy HEX Dump** | New on macOS — not in the Windows menu |
| 7 | Options... | Help... | macOS Help is a simple About dialog, not the Windows [HelpDlg](HexEditor/src/HelpDlg/) URL-control window |
| 8 | Help... | — | One fewer entry on macOS |

The Windows plugin separately exposes Find / Replace / Goto from inside the docked HEX dialog rather than the plugin menu; those entry points have no macOS equivalent yet (see "Not yet ported" below).

Menu wiring on Windows is in [Hex.cpp:100-117](HexEditor/src/Hex.cpp#L100-L117); on macOS in [HexEditor.mm:1885-1923](macos/src/HexEditor.mm#L1885-L1923). Stub bodies are at [HexEditor.mm:1851-1879](macos/src/HexEditor.mm#L1851-L1879).

### Editor capabilities

**Implemented on macOS:**
- Inline overlay that swaps the active Scintilla view for an `NSTableView`-based hex grid (offset / hex bytes / ASCII columns)
- Direct byte overwrite from both hex and ASCII columns; append at EOF
- Range selection across hex and ASCII panes
- Cut / Copy / Paste / Delete / Select All — both context menu and host **Edit** menu via responder-chain integration
- Cmd-Z / Cmd-Shift-Z undo and redo, applied as Scintilla undo groups
- Cmd+Home / Cmd+End cursor jumps to document start/end (bare `End` only goes to row end — see [TESTING.md:127-129](macos/TESTING.md#L127-L129))
- Bookmark toggling via context menu
- Copy HEX Dump to clipboard (text format)
- Three accessibility identifiers exposed for UI test reach (`hex-editor.root`, `hex-editor.table`, `hex-editor.status`)

**Not yet ported from Windows** (present in [HexEditor/src/](HexEditor/src/), absent on macOS):
- Find / Replace dialog ([UserDlg/FindReplaceDialog.cpp](HexEditor/src/UserDlg/FindReplaceDialog.cpp))
- Goto offset dialog ([UserDlg/GotoDialog.cpp](HexEditor/src/UserDlg/GotoDialog.cpp))
- Compare HEX with diff highlighting ([UserDlg/CompareDialog.cpp](HexEditor/src/UserDlg/CompareDialog.cpp))
- Pattern replace ([UserDlg/PatternDialog.cpp](HexEditor/src/UserDlg/PatternDialog.cpp))
- Insert Columns ([OptionDlg/ColumnDialog.cpp](HexEditor/src/OptionDlg/ColumnDialog.cpp))
- Options dialog with color/font configuration ([OptionDlg/OptionDialog.cpp](HexEditor/src/OptionDlg/OptionDialog.cpp))
- Help dialog with embedded URL controls ([HelpDlg/](HexEditor/src/HelpDlg/))
- Word / DWORD / LONG byte grouping (Windows `HEX_BYTE`/`HEX_WORD`/`HEX_DWORD`/`HEX_LONG` from [Hex.h:70-73](HexEditor/src/Hex.h#L70-L73))
- Little-endian / big-endian display modes
- Configurable column count and address width
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
