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

## Pre-commit checklist

**Always run before `git commit`:**

```sh
bash macos/scripts/pre-commit-tests.sh
```

This runs every test tier in dependency order, fastest-first, aborting at the first failure so a 5 ms unit-tier regression doesn't burn 22 minutes of UI run before being noticed:

1. **Unit (host)** — `ctest -L unit` against `macos/build/`. ~0.01 s.
2. **Unit + ASan/UBSan (host)** — `ctest -L unit` against `macos/build-asan/`. ~0.5 s. Catches heap-buffer-overflow / use-after-free / signed-overflow at < 1 ms feedback so they don't surface 22 minutes deep into the UI run.
3. **Plugin smoke (host)** — `ctest -L smoke` against `macos/build/`. `dlopen`s the plugin and checks the host contract. ~0.4 s.
4. **Fuzz / robustness (host)** — `ctest -L fuzz` against `macos/build-fuzz/`. 4 libFuzzer harnesses × 30 s = ~2 min. Exercises the parser/decoder paths against random inputs.
5. **Full XCTest UI (VM)** — `macos/scripts/test-ui.sh`. ~22 min on the Parallels VM. Locks VM keyboard/mouse; don't use the VM for anything else while this runs.

The script accepts `--skip-fuzz` (cosmetic-only commits) and `--skip-ui` (fast pre-push gate), but the full sequence is required before any commit. Skipping a tier means trusting that nothing it would have caught has been introduced — only OK when the change is genuinely orthogonal (whitespace, a docs file).

**First-time setup.** Each tier expects its own pre-configured CMake build directory. Run these once:

```sh
# Tier 1 + 3 (release build with unit + smoke targets)
cmake -S macos -B macos/build -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos

# Tier 2 (sanitized build)
cmake -S macos -B macos/build-asan -DENABLE_SANITIZERS=ON \
    -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos

# Tier 4 (fuzz build — needs Homebrew LLVM, see macos/CMakeLists.txt)
cmake -S macos -B macos/build-fuzz -DENABLE_FUZZ_TESTS=ON \
    -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++ \
    -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang \
    -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos
```

After that, `pre-commit-tests.sh` keeps each build directory current via `cmake --build`; you don't need to rerun configure unless something changes the toolchain (Xcode upgrade, Homebrew LLVM bump, etc.).

## XCTest UI tests

Host-level UI automation uses an XcodeGen-generated `.xcodeproj` under `macos/ui-tests-xcode/`. SwiftPM XCTest packages cannot host `XCUIApplication` (it requires a UI test bundle, not a unit test bundle), so we use a real Xcode project with a minimal stub runner app and a `bundle.ui-testing` test target. `project.yml` is checked in; the generated `.xcodeproj` is gitignored and rebuilt on demand.

UI tests run inside a Parallels VM, **not** on the host. XCUITest synthesizes events through Window Server and locks the active session's keyboard/mouse for the duration of the run — having that happen on the host machine you're typing on is unworkable. The VM is one-time set up via `macos/scripts/vm-bootstrap.sh`; thereafter all runs go through the host-side wrapper described next.

### One-time setup: stable code-signing identity for the test runner

**Why this exists.** The XCUITest runner needs Accessibility permission (TCC) on the VM to drive the UI. macOS keys TCC grants by the binary's *designated requirement* (DR). Ad-hoc signing — Xcode's default — puts the binary's SHA-256 hash into the DR, so any rebuild (even a comment-only edit) produces a new hash and silently invalidates the previous grant; the next run then dies after a 60-second pause with "Timed out while enabling automation mode". Signing the runner with a stable self-signed cert puts the cert's identity into the DR instead, so the grant survives any rebuild as long as the same cert is used.

**One command.** Run the installer, in a **Terminal *inside* the VM** (Parallels GUI window, not over SSH — the trust step needs GUI auth that SSH can't supply):

```sh
bash ~/vm-local/NPP_HexEdit/macos/scripts/install-test-codesign-cert.sh
```

What it does:

1. Creates a dedicated keychain at `~/Library/Keychains/NPP-HexEdit-Codesign.keychain-db` with no auto-lock (password is hard-coded `npp-hexedit-test`; the keychain only ever holds this one self-signed local-test cert, so leaking the password leaks nothing useful).
2. Adds it to the user's keychain search list.
3. Generates a self-signed cert + private key (RSA 2048, 10-year validity, codeSigning EKU) using `/usr/bin/openssl` (system LibreSSL — Homebrew's OpenSSL 3.x is incompatible with the Keychain importer).
4. Imports the identity with `-A` (any-app access) and sets the partition list to `apple-tool:,apple:,codesign:,unsigned:` so codesign can use the key from any context including SSH.
5. **Prompts once** (Keychain Access GUI) for your **login** password to mark the cert as trusted for code signing. Approve.

After it finishes, run any test to land the first signed runner. The first signed run will trigger one final Accessibility prompt on the VM desktop — grant it via System Settings → Privacy & Security → Accessibility → tick HexEditorUITestRunner. From then on, the grant persists across all rebuilds (comment edits, source changes, DerivedData wipes, signed runs and ASan runs alike).

**Verifying the install.** Over SSH from the host:

```sh
ssh npp-vm 'security find-identity -v -p codesigning ~/Library/Keychains/NPP-HexEdit-Codesign.keychain-db'
```

You should see one entry: `1 valid identities found`, identity name `NPP-HexEdit Test Codesign`. If `find-identity` shows zero, re-run the install script.

**Why a dedicated keychain instead of `login.keychain`.** SSH sessions run in a different launchd domain than your GUI session, and login-keychain unlock state doesn't propagate between domains — `xcodebuild` invoked over SSH gets `errSecInternalComponent` because it can't access keys in your interactively-unlocked login keychain. A separate keychain we never lock, with explicit partition-list entries that allow codesign access, sidesteps that entirely. `vm-test.sh` runs `security unlock-keychain` against this keychain at the start of every run so the SSH-domain Security agent has it cached.

**Common pitfalls.**

| Symptom | Cause | Fix |
| --- | --- | --- |
| `MAC verification failed (wrong password?)` during install | Homebrew OpenSSL 3.x exported the .p12 with PBE that Keychain can't decrypt | Already handled by the script (pins to `/usr/bin/openssl`). If you see this anyway, your `/usr/bin/openssl` was replaced — reinstall macOS Command Line Tools. |
| `User canceled the operation` during import | Hit cancel on a dialog because the keychain self-relocked between unlock and import | Already handled by current script (passes no flags to `set-keychain-settings`, so no auto-lock). If you see this with the current script, delete the keychain and re-run. |
| `errSecInternalComponent` during codesign | Partition list missing the partition codesign runs in | Already handled (script sets `apple-tool:,apple:,codesign:,unsigned:`). If you see this anyway, run `security set-key-partition-list -S apple-tool:,apple:,codesign:,unsigned: -s -k npp-hexedit-test ~/Library/Keychains/NPP-HexEdit-Codesign.keychain-db` over SSH and retry. |
| Keychain password dialog rejects `npp-hexedit-test` | Keychain self-locked due to a stale install of an older script version | Delete the keychain (`security delete-keychain ~/Library/Keychains/NPP-HexEdit-Codesign.keychain-db`) and re-run the install script. |
| `vm-test.sh` errors `code-signing identity ... not found` | Install script wasn't run on the VM | Run it (in VM Terminal, not SSH). |
| Trust prompt at end of install rejects your password | Caps Lock / wrong keyboard layout / IME interfering | Use Keychain Access GUI fallback: open Keychain Access, switch to NPP-HexEdit-Codesign keychain, right-click the cert → Get Info → Trust → Code Signing → Always Trust. Same effect. |

**Rotating the cert** (e.g., after a security review). Delete the keychain on the VM and re-run the install script:

```sh
security delete-keychain ~/Library/Keychains/NPP-HexEdit-Codesign.keychain-db
bash ~/vm-local/NPP_HexEdit/macos/scripts/install-test-codesign-cert.sh
```

You'll need to re-grant Accessibility once after the first run with the new cert — same flow as initial setup.

### Running UI tests

One command, from the host:

```sh
macos/scripts/test-ui.sh                          # all UI tests
macos/scripts/test-ui.sh testFooBar               # a single test by name
macos/scripts/test-ui.sh testFoo testBar testBaz  # a subset
macos/scripts/test-ui.sh --list                   # enumerate all test names
macos/scripts/test-ui.sh --failed                 # re-run only last run's failures
macos/scripts/test-ui.sh --clean                  # also wipe Xcode DerivedData on VM
macos/scripts/test-ui.sh --asan                   # build + load ASan-instrumented plugin (~15% slower on the VM, catches plugin-side memory bugs)
macos/scripts/test-ui.sh --re-bootstrap           # repair a broken VM env
macos/scripts/test-ui.sh --dashboard              # open dashboard.html in browser
```

The wrapper SSHes to the VM (`npp-vm`), syncs the source tree and Notepad++.app to VM-local paths (Parallels' shared-folder protocol caches reads aggressively, so we work from a checksum-synced mirror), runs the tests, and copies the results back. After the run it also rebuilds + installs the host's `HexEditor.dylib` from the same source so your own Notepad++ matches whatever the VM just tested (restart Notepad++ to load the new dylib). If the host build directory hasn't been configured yet, that step is skipped with a hint to run `cmake -S macos -B macos/build` once.

`--asan` is the periodic safety-net run. The plugin is built under `-fsanitize=address,undefined`; the runtime is then injected into NPP at process launch via `DYLD_INSERT_LIBRARIES` (set in the XCUITest helper's `launchEnvironment`). Any heap-buffer-overflow / use-after-free / signed-overflow inside our runtime path aborts with a sanitizer stack trace and fails the test. Cost: ~15% slower than the regular UI suite on the Parallels VM (~25 min vs. ~22 min, measured 2026-05-02 over a 59-test run). The host plugin is **not** auto-replaced on `--asan` runs (you keep your fast day-to-day plugin). Catches the bug class that the unit tier already protects against (via `hexedit::SciReader` + `FakeScintilla`) plus anything in the plugin's runtime path the unit tests don't reach (AppKit interaction, NSEvent handling, draw paths). Why DYLD injection: a dlopen-loaded ASan-instrumented dylib aborts NPP at "Interceptors are not working" because dyld brings up the plugin after the host's first malloc; injecting at launch sidesteps that. NPP-Mac is ad-hoc signed with no entitlements, so SIP doesn't strip the env var. After the run, three artefacts land at stable paths under [macos/ui-tests-xcode/build/](ui-tests-xcode/build/):

- `dashboard.html` — human-readable dashboard. Per-test status and last 20 runs. Open with `test-ui.sh --dashboard`.
- `dashboard.md` — same content, Markdown.
- `test-results.md` — detailed result of the most recent run only.
- `run-history.json` — accumulated history (read by the dashboard generator).

### Adding a UI test

Edit [macos/ui-tests-xcode/Tests/HexEditorUITests.swift](ui-tests-xcode/Tests/HexEditorUITests.swift). Any function whose name begins with `func test` is automatically picked up by `xcodebuild`, by `--list`, by the dashboard's "All tests" section, and by the canonical source list. Save and run — no other registration needed.

Conventions:

- Name tests after the user-visible behavior (`testHexBookmarkClickPath`), not the implementation (`testTableViewBookmarkColumnZeroClick`).
- Use the helpers at the top of the file (`launchNotepad`, `createBufferWithText`, `invokeHexEditorMenu`) rather than open-coding XCUI sequences — see "Patterns the harness depends on" below.
- Read the structural diagnostic via `HexCursorState.read(from: app)` rather than scraping AX values one at a time. New diagnostic fields go through that struct.

### Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Cannot reach VM at host alias 'npp-vm'` | Start the VM in Parallels; verify `ssh npp-vm true` works manually. |
| `error: env file references ephemeral path` | An old buggy bootstrap captured a `/dev/fd/N` path. Run `test-ui.sh --re-bootstrap`. |
| `error: Notepad++.app not found` | Build Notepad++ macOS on the host first. The wrapper rsyncs the build product to the VM. |
| Dashboard shows tests "—" (never run) | Those tests are in the source but haven't run since `run-history.json` was started. Run them once. |
| Run hangs at "Timed out while enabling automation mode" | Runner's TCC Accessibility grant was revoked (e.g. by `--clean`). Re-grant on the VM: System Settings → Privacy & Security → Accessibility → enable `HexEditorUITests-Runner`. |
| Stale-bytes problems (test asserts old behavior despite fresh source) | Should be impossible after the rsync change. If it happens, `test-ui.sh --clean` forces a from-scratch xcodebuild. |
| Host's Notepad++ shows old plugin behavior after a code edit | Restart Notepad++ on the host. `test-ui.sh` rebuilds + installs the host plugin after every run, but macOS doesn't hot-reload dylibs in a running app. |

### Direct invocation (rarely needed)

If you must run from the VM directly without the host wrapper:

```sh
ssh npp-vm bash -lc '~/vm-test-local.sh'                          # full suite
ssh npp-vm bash -lc '~/vm-test-local.sh -only-testing:HexEditorUITests/HexEditorUITests/testFoo'
```

Or via CTest on the VM (label `xctest`):

```sh
ssh npp-vm bash -lc 'ctest --test-dir ~/build-NPP_HexEdit -L xctest --output-on-failure'
```

`NPP_MACOS_APP=/path/to/Notepad++.app` overrides the default app location if you're testing a specific host build outside the standard sibling layout.

### Current XCTest coverage

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
