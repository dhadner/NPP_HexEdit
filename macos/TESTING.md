# Testing strategy

The macOS port should use Scintilla as the source of truth for document bytes and undo/redo history. Tests should avoid creating a second model of editor state that can drift from the real plugin behavior.

## Layers

1. Pure C++ unit tests

   Platform-neutral core lives at `macos/src/core/HexCore.{h,cpp}` and links neither Cocoa nor Scintilla. Tests live at `macos/tests/HexCoreTests.cpp` and run as the `HexEditorCoreTests` CTest target (label `unit`).

   Run:

   ```sh
   ctest --test-dir macos/build-universal -L unit --output-on-failure
   ```

   Currently extracted:

   - `hexedit::hexDigitValue` — hex digit to nibble conversion
   - `hexedit::isVisibleEditableOffset` — visible vs append-slot detection
   - `hexedit::clampCursor`, `moveCursor`, `cursorToLineStart`, `cursorToLineEnd`, `cursorToDocumentStart`, `cursorToDocumentEnd`, `navigateLeft`, `navigateRight` — cursor movement rules
   - `hexedit::selectedOrCurrentRange` — cut/copy/delete target range
   - `hexedit::planHexDigitEdit` — hex nibble overwrite/append
   - `hexedit::planAsciiByteEdit` — ASCII overwrite/append

   Still to extract:

   - select-all state
   - paste range planning over selection
   - bookmark row math
   - operation planning for cut/delete

2. Adapter tests with fakes

   Keep Scintilla calls behind a tiny adapter interface. Unit tests can use a fake byte buffer that records target ranges, replacement bytes, and undo-group boundaries. This verifies that every mutation becomes one Scintilla undo action without needing the real editor view.

   Required assertions:

   - every write starts and ends one undo action
   - overwrite replaces exactly one byte
   - append uses a zero-length target at EOF
   - delete/cut uses a zero-length replacement
   - paste over selection replaces the selected byte range
   - undo/redo asks Scintilla, then reloads the visible byte cache

3. Plugin smoke tests

   `tests/HexPluginSmokeTests.cpp` `dlopen`s the built dylib and verifies the host contract without launching Notepad++. Runs as the `HexEditorPluginSmokeTests` CTest target (label `smoke`). 25 assertions, runs in milliseconds.

   ```sh
   ctest --test-dir macos/build-universal -L smoke --output-on-failure
   ```

   Currently asserts:

   - All five exports resolve via `dlsym`: `setInfo`, `getName`, `getFuncsArray`, `beNotified`, `messageProc`.
   - `getName()` returns `"HexEditor"`.
   - `getFuncsArray(&n)` returns a non-NULL pointer with `n == 8`.
   - Each `funcItem[i]._itemName` matches the expected eight menu titles.
   - Each `funcItem[i]._pFunc` is non-NULL.

   The test calls `setInfo` with a zeroed `NppData` first because the plugin populates `funcItem[]` inside that handler. No menu callbacks are invoked, so the zeroed handles are never dereferenced.

4. Manual/integration test checklist

   Some behavior depends on AppKit responder routing and the live Notepad++ macOS editor. Keep a short manual checklist until we have host-level UI automation.

   Required scenarios:

   - open hex view from top and from a scrolled source document
   - type hex nibbles, ASCII bytes, and append at EOF
   - select bytes in hex and ASCII panes
   - cut/copy/paste/delete from context menu
   - cut/copy/paste/delete/select-all from the main Edit menu
   - Cmd-Z and Cmd-Shift-Z after each mutation type
   - toggle back to text view and verify document bytes
   - switch/close buffers while hex view is open

## XCTest UI tests

Host-level UI automation uses an XcodeGen-generated `.xcodeproj` under `macos/ui-tests-xcode/`. SwiftPM XCTest packages cannot host `XCUIApplication` (it requires a UI test bundle, not a unit test bundle), so we use a real Xcode project with a minimal stub runner app and a `bundle.ui-testing` test target. `project.yml` is checked in; the generated `.xcodeproj` is gitignored and rebuilt on demand.

Set `NPP_MACOS_APP=/path/to/Notepad++.app` to test a specific host build. If unset, the tests default to the sibling checkout at `../notepad-plus-plus-macos/build/Notepad++.app`.

Run directly:

```sh
macos/ui-tests-xcode/run-tests.sh
```

Run through CTest:

```sh
ctest --test-dir macos/build-universal -L xctest --output-on-failure
```

Current XCTest coverage:

- `testHostApplicationLaunches` — launches Notepad++ macOS via `XCUIApplication(url:)` and waits for foreground.
- `testHexEditorPluginMenuIsPresent` — asserts the `HexEditor` submenu under `Plugins`.
- `testViewInHexToggle` — toggles `Plugins > HexEditor > View in HEX` on and off, asserting the hex table appears and disappears (queried by accessibility identifier `hex-editor.table`).
- `testStatusLabelReportsByteCount` — seeds the buffer with a known string and asserts the status label reports the exact byte count.
- `testEditMenuActionsRouteToHexOverlay` — with the hex overlay focused, asserts that `Cut`, `Copy`, `Paste`, `Delete`, and `Select All` in the host `Edit` menu are all *enabled*, proving the plugin's responder chain integration.
- `testEditMenuCopyFromHexView` — Edit > Select All followed by Edit > Copy from a seeded "Hex" buffer round-trips through the system pasteboard and asserts the pasteboard string equals the lowercase space-separated hex form `"48 65 78"` (Windows-faithful Copy semantics).
- `testHexByteAppendUndoRedo` — seeds a 3-byte buffer, navigates to EOF, types a hex digit to append, asserts byte count goes 3→4, asserts Cmd+Z reverts to 3, asserts Cmd+Shift+Z restores to 4. Validates the full plan-edit-undo loop end-to-end.
- `testHexCutAndUndo` — seeds 6 bytes, Edit > Select All + Edit > Cut, asserts status reports empty document; Cmd+Z restores to 6, Cmd+Shift+Z re-cuts. Exercises the menu → responder → plugin `cut:` path end-to-end.
- `testHexPasteAtCmdEnd` — seeds 3 bytes, sends `Cmd+End` (jumps cursor to EOF via the new plugin shortcut), pastes 3 bytes from clipboard via Edit > Paste, asserts byte count grows from 3 to 6. Exercises the Paste fallback that decodes plain-text pasteboard content as raw bytes when it is not parseable as hex.
- `testContextMenuCommands` — right-clicking the hex table exposes the current Windows-faithful set: Undo/Redo, Cut/Copy/Paste/Delete, Cut Binary Content / Copy Binary Content / Paste Binary Content, and the macOS-only Zoom In/Out/Restore. Select All and Toggle Bookmark are deliberately not in the context menu — Select All routes through the host Edit menu / Cmd+A, bookmarks toggle by clicking the offset column.

The hex view exposes three accessibility identifiers (defined in `macos/src/HexEditor.mm` and mirrored in the Swift test file):

- `hex-editor.root` — the container view
- `hex-editor.table` — the hex table
- `hex-editor.status` — the status label

See `macos/ui-tests-xcode/README.md` for signing, sandbox, and runner constraints.

### Patterns the harness depends on

1. **Disable session restore.** `XCUIApplication.launchArguments = ["-nosession"]` makes Notepad++ launch with a single fresh empty buffer. Without this, session restore loads documents from `~/.notepad++/session.plist` and the test runs against unpredictable content.

2. **Seed buffers via clipboard + Edit > Paste.** `XCUIApplication.typeText(_:)` is silently dropped by Scintilla in this sandbox+runner configuration — synthetic key events do not reach Scintilla's input handler. Workaround: write the seed string to `NSPasteboard.general`, then click `Edit > Paste` via the menu bar. Menu-bar interactions go through XCUI's accessibility path and route correctly. Implemented in the `createBufferWithText` helper.

3. **typeText *does* work on the hex view itself.** Once the hex overlay is active and first responder, `app.typeText("F")` reaches `HexTableView.keyDown:` correctly. So the byte-edit flow uses clipboard for seeding (Scintilla side) and `typeText` for hex-digit input (plugin side).

4. **One-second settle after toggling into hex view.** Without it, the host's Edit menu validation can run against a stale first responder and items report disabled even when they should be enabled. The plugin's `[hexTableView.window makeFirstResponder:]` is synchronous in AppKit but XCUI's next action can race ahead of focus propagation.

5. **`End` reaches end-of-row only.** Use `Cmd+End` (and `Cmd+Home`) to jump to document end/start — the plugin's `HexTableView.keyDown` special-cases these in the `commandOrControl != 0` branch before falling through to super. Without `Cmd+End`, append-at-EOF tests would be limited to ≤16-byte buffers.

## CMake shape

CTest runs a tiny assertion-based executable that links the same core sources as the plugin. No third-party test framework yet — see `tests/HexCoreTests.cpp` for the `HEX_EXPECT` / `HEX_EXPECT_EQ` runner.

The plugin and the unit-test executable both compile `src/core/HexCore.cpp`. `HexEditor.mm` is the thin AppKit/Notepad++ adapter that constructs `hexedit::DocumentView`/`Selection`/`CursorState` from globals, calls a pure planning function, and applies the resulting `ByteEditOperation` to Scintilla inside one undo action.

## Edit operation contract

```cpp
struct hexedit::ByteEditOperation {
    std::size_t offset;
    std::size_t replacedByteCount;
    std::vector<std::uint8_t> replacement;
    hexedit::CursorState nextCursor;
};
```

Planners (`planHexDigitEdit`, `planAsciiByteEdit`) return `false` if the edit is not allowed (offset outside visible/editable range, invalid hex digit, etc.). The adapter layer applies the operation to Scintilla and writes back the cursor state.
