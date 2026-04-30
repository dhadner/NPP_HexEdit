# HexEditor XCTest UI tests

Host-level XCTest UI automation against the Notepad++ macOS app with the HexEditor plugin installed.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — only the spec file and the test sources are checked into git.

## Layout

- `project.yml` — XcodeGen spec (source of truth)
- `TestRunner/` — minimal stub host app required by macOS UI test bundles
- `Tests/HexEditorUITests.swift` — the test cases
- `run-tests.sh` — regenerates the project and invokes `xcodebuild test`
- `HexEditorUITests.xcodeproj/` (generated, gitignored)
- `build/` (xcodebuild result bundles, gitignored)

## Prerequisites

- Xcode with command line tools selected
- `xcodegen` (`brew install xcodegen`)
- A built Notepad++ macOS app bundle (defaults to `../../../notepad-plus-plus-macos/build/Notepad++.app`)
- The HexEditor plugin installed at `~/.notepad++/plugins/HexEditor/HexEditor.dylib` for the plugin-menu test

## Run

```sh
./run-tests.sh
```

With an explicit host app path:

```sh
NPP_MACOS_APP=/path/to/Notepad++.app ./run-tests.sh
```

Through CTest (after configuring CMake with testing enabled):

```sh
ctest --test-dir ../build-universal -L xctest --output-on-failure
```

## Current coverage

- `testHostApplicationLaunches` — launches Notepad++ macOS via `XCUIApplication(url:)` and verifies it foregrounds.
- `testHexEditorPluginMenuIsPresent` — clicks the `Plugins` menu and verifies `HEX-Editor` is present.
- `testViewInHexToggle` — toggles the hex overlay on/off and asserts the table appears/disappears.
- `testStatusLabelReportsByteCount` — seeds buffer and asserts the status label reports the exact byte count.
- `testEditMenuActionsRouteToHexOverlay` — `Cut`/`Copy`/`Paste`/`Delete`/`Select All` in the host Edit menu are all enabled when the hex overlay has focus.
- `testEditMenuCopyFromHexView` — Edit > Select All + Edit > Copy round-trips through the system pasteboard.
- `testHexByteAppendUndoRedo` — seeds 3 bytes, navigates to EOF, types a hex digit to append, validates byte-count after append, Cmd+Z, and Cmd+Shift+Z.
- `testHexCutAndUndo` — Edit > Select All + Edit > Cut empties the buffer; Cmd+Z restores it; Cmd+Shift+Z re-cuts.
- `testHexPasteAtCmdEnd` — Cmd+End jumps to EOF, then Edit > Paste with the clipboard pre-populated grows the buffer.
- `testContextMenuCommands` — right-click context menu exposes the expected nine commands.

## Accessibility identifiers

Defined in `macos/src/HexEditor.mm` and mirrored in `Tests/HexEditorUITests.swift`:

- `hex-editor.root` — container view
- `hex-editor.table` — NSTableView
- `hex-editor.status` — status NSTextField

The status label exposes its text as the AX *value* (not label). Use `(element.value as? String) ?? element.label` to read.

## Notepad++ launch arguments

The harness passes `-nosession` to suppress session restore on launch. Without it, Notepad++ macOS reopens documents from `~/.notepad++/session.plist`, making test buffer state non-deterministic.

## Buffer seeding

`XCUIApplication.typeText(_:)` does **not** reach Scintilla in this sandbox+runner configuration — synthetic key events are silently dropped before Scintilla's input handler sees them. The harness seeds buffers by writing to `NSPasteboard.general` and clicking `Edit > Paste` via the menu bar, which routes through XCUI's accessibility path and works reliably.

`typeText` *does* work once the hex overlay is the first responder, so the plugin's keyDown handler receives the byte-edit characters correctly.

## Next UI tests

- Per-cell hex-byte value assertions (would need accessibility identifiers on table cells or columns).
- Bookmark toggle round-trips (click offset column, verify red highlight, click again to clear).
- ASCII-pane editing flow — tab between hex/ASCII fields, type printable bytes, verify.
- Multi-buffer scenarios — switch between hex view and another tab without leaks.

## Notes on the test runner

- The runner uses ad-hoc code signing (`CODE_SIGN_IDENTITY = "-"`).
- Xcode's UI test framework adds `com.apple.security.app-sandbox = true` to the runner — `~/.notepad++/` is therefore not readable by the test runner. File-system precondition checks against the user home directory should not be used; if the plugin is not installed the menu test will fail with a clear message instead.
- `XCUIApplication(url:)` does not require Accessibility permission for `wait(for: .runningForeground)` or for clicking menu items; the test framework's temp-exception entitlements cover it.
