# Developer guide

How to build, test, and contribute to the macOS port of the Nextpad++ HexEditor
plugin. If you only want to *use* the plugin, see [README.md](README.md) instead.

## Quick start

```sh
# 1. Clone this repo and the host repo as siblings (any parent directory works
#    — the build only requires they share a parent. Override the discovery path
#    with -DNPP_MACOS_DIR= if you'd rather lay them out differently).
git clone https://github.com/<your-fork>/NPP_HexEdit.git
git clone https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos.git nextpad-plus-plus

# 2. Install Nextpad++. Either drag the released .app to /Applications/, or
#    build it from the host repo (follow its Build-Instructions.md).
#    Tests look for /Applications/Nextpad++.app by default; override with
#    NPP_MACOS_APP=/path/to/Nextpad++.app.

# 3. Build, install, and smoke-test the plugin.
cd ../NPP_HexEdit
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure
```

If the unit + smoke tiers pass and the host launches with the plugin enabled
(Plugins → HexEditor menu present), you have a working dev loop.

## Prerequisites

| Tool | Why | Install |
| --- | --- | --- |
| macOS 11+ | Build target | n/a |
| Xcode 15+ | Compiler, SDK, XCTest | App Store, or `xcodes install --latest` |
| Xcode CLT | `xcode-select`, `clang`, `cmake` discovery | `sudo xcode-select --install` |
| Homebrew | Dependency installer | <https://brew.sh> |
| CMake ≥ 3.20 | Build system | `brew install cmake` |
| Git | Source control | `brew install git` |
| XcodeGen | Generates the XCTest UI project from `project.yml` | `brew install xcodegen` |

XcodeGen is only needed for the XCTest UI tier. The unit and smoke tiers
depend only on CMake + the toolchain.

## Repository layout

```text
NPP_HexEdit/
├── HexEditor/                 — original Windows plugin source (Jens Lorenz, 2006). Unchanged.
├── macos/                     — the macOS port
│   ├── CMakeLists.txt         — describes how to build, install, and run tests
│   ├── src/
│   │   ├── HexEditor.mm       — the macOS-specific code: AppKit UI + Nextpad++ glue
│   │   └── core/HexCore.{h,cpp} — pure logic (no UI or editor calls), shared with unit tests
│   ├── resources/             — Localizable.<lang>.strings text files
│   ├── tests/                 — HexCoreTests (logic) + HexPluginSmokeTests (load check)
│   ├── ui-tests-xcode/        — UI test suite that drives the real Nextpad++ app
│   ├── scripts/               — VM helpers (vm-bootstrap.sh, vm-test.sh)
│   ├── README.md              — port-specific notes
│   └── TESTING.md             — per-tier test contract + manual checklist
├── DEVELOPER.md               — this file
├── CHANGELOG.md               — release notes
└── README.md                  — user-facing overview
```

The split between `HexEditor.mm` and `core/HexCore.{h,cpp}` exists so the unit
tests can link the *exact same* logic the plugin uses — no fakes or mocks
needed. Anything that could be expressed without touching macOS APIs lives in
`HexCore`.

## Sibling host checkout

You need two things from
[nextpad-plus-plus](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos):

| Need | Required for | Source |
| --- | --- | --- |
| Headers (`NppPluginInterfaceMac.h`, Scintilla `.h`) | Compiling the plugin | Repo source — must be present at `NPP_MACOS_DIR` |
| `Nextpad++.app` binary | XCTest UI tier launches it | Install via the host's release `.dmg`, or build from source |

By default CMake looks for the host repo as a sibling directory of `NPP_HexEdit`
— in other words, both repos share the same parent. The parent's name doesn't
matter (`~/src/NPP_HexEdit` next to `~/src/nextpad-plus-plus`,
`~/Documents/GitHub/NPP_HexEdit` next to `~/Documents/GitHub/nextpad-plus-plus`,
or anything else — only the relative position matters):

```text
<any-parent>/
  NPP_HexEdit/
  nextpad-plus-plus/
```

If your layout is different, pass `-DNPP_MACOS_DIR=/abs/path/to/nextpad-plus-plus`
on the first `cmake -S macos -B macos/build-universal …` invocation (the
"configure" step that generates the build system; this is separate from
`cmake --build`, which only compiles). Example:

```sh
cmake -S macos -B macos/build-universal \
    -DCMAKE_BUILD_TYPE=Release \
    -DNPP_MACOS_DIR=/Users/me/projects/nextpad-plus-plus
```

The path is cached in `macos/build-universal/CMakeCache.txt`, so you only need
to pass it once. Subsequent `cmake --build` runs reuse it.

For the binary, the XCTest tier reads `NPP_MACOS_APP=/abs/path/to/Nextpad++.app`
to locate the host. If unset, it defaults to `/Applications/Nextpad++.app`
(the standard installed location, present on both host and any test VM).

**Using the installed `/Applications/Nextpad++.app`** is the default and what
this repo's pre-commit suite assumes. The bundle identifier is
`org.nextpadplusplus.mac`.

**Building the host from source** gives you a guaranteed-compatible binary
matched to the headers your plugin compiled against. Multi-minute build, run
once per host-repo update. Point the tests at it:

```sh
NPP_MACOS_APP=/path/to/your-build/Nextpad++.app macos/ui-tests-xcode/run-tests.sh
```

The risk: if the installed binary was built against a different version of
the NPP plugin API than your headers, the plugin can fail to load at runtime
(symptom: HexEditor doesn't appear under the host's Plugins menu). When the
host's plugin API is stable, this isn't an issue. If you see the plugin not
load, build the host from source and try again — that eliminates version
drift as a variable.

Either way, the plugin itself rebuilds in seconds every time you change a
`.mm` / `.cpp` / `.h` file.

## Build & install

```sh
# Universal binary (arm64 + x86_64), Release.
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal

# Install to ~/.nextpad++/plugins/HexEditor/ (also copies the .strings files + toolbar icons).
cmake --install macos/build-universal
```

Faster Apple-Silicon-only build for iteration:

```sh
cmake -S macos -B macos/build-arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Debug
cmake --build macos/build-arm64
```

After install, restart Nextpad++ — plugins load on startup.

## Tests

Three tiers, in increasing cost and decreasing speed.

### Tier 1 — unit (`HexEditorCoreTests`, ~10 ms)

Pure C++, no Cocoa. Links the same `HexCore.cpp` the plugin links. Always run
this tier before pushing.

```sh
ctest --test-dir macos/build-universal -L unit --output-on-failure
```

Add new cases at [macos/tests/HexCoreTests.cpp](macos/tests/HexCoreTests.cpp).
Anything that can be tested without Cocoa (cursor math, edit planners, parsing,
diff, search) belongs here.

### Tier 2 — smoke (`HexEditorPluginSmokeTests`, ~400 ms)

A "does the plugin even load?" test. It dynamically loads the built `.dylib`
file and checks that:

- the five functions Nextpad++ expects to find are all there
- `getName()` returns `"HexEditor"`
- the right number of menu items are registered, with the expected English titles

The test forces the plugin to use English so the title assertions don't depend
on your Mac's language setting. Run it via:

```sh
ctest --test-dir macos/build-universal -L smoke --output-on-failure
```

### Tier 3 — XCTest UI (~14 min for full suite, ~30s per single test)

The full end-to-end test: launches the real Nextpad++ app with the plugin
installed and drives it through clicks and keystrokes. Catches the kinds of
bugs the first two tiers can't see — menu items not lighting up, dialogs
showing the wrong text, hex rows clipping at the top of the view, etc.

```sh
# Full suite
macos/ui-tests-xcode/run-tests.sh

# Subset (much faster — useful while iterating on a specific feature)
macos/ui-tests-xcode/run-tests.sh \
  -only-testing:HexEditorUITests/HexEditorUITests/testHexCursorMatchesScintillaCaretAfterPaste

# Or via CTest
ctest --test-dir macos/build-universal -L "ui|xctest" --output-on-failure
```

Result reporting: every run writes a Markdown summary at
`macos/ui-tests-xcode/build/test-results.md` with pass/fail counts, failure
messages, and a per-test status list. Open it in any editor to see what
happened — no need to scroll xcodebuild output.

**Pre-flight for UI tests:**

1. Plugin must be installed: `cmake --install macos/build-universal`.
2. Quit any other running `Nextpad++.app` (the suite skips itself if a
   different bundle at `org.nextpadplusplus.mac` is already running, since
   `XCUIApplication(url:)` cannot launch a second instance under the same
   bundle ID).
3. Grant Accessibility permission to Xcode in
   System Settings → Privacy & Security → Accessibility. XCUITest synthesizes
   keyboard/mouse events through this permission. If tests time out at
   "Setting up automation session", run `tccutil reset Accessibility com.apple.dt.Xcode`
   and re-grant.

**The UI tier locks your keyboard and mouse for the duration of the run** —
~14 min for the full suite. The next section describes how to avoid this.

### Tier 4 — Sanitizers + libFuzzer (`ctest -L fuzz`, opt-in)

A separate build directory builds the C++ tests under AddressSanitizer +
UndefinedBehaviorSanitizer, optionally with libFuzzer harnesses against the
parsers in HexCore that consume attacker-controlled data (the custom-UTI
binary payload + the Q2.b text fallback). See
[macos/fuzz/README.md](macos/fuzz/README.md) for the harness inventory.

ASan + UBSan only (works with Apple Clang, no extra install):

```sh
cmake -S macos -B macos/build-asan -DENABLE_SANITIZERS=ON -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build macos/build-asan
ctest --test-dir macos/build-asan -L "unit|smoke" --output-on-failure
```

Adds ASan + UBSan + libFuzzer (requires `brew install llvm` because Apple
Clang ships the `-fsanitize=fuzzer` flag but not the runtime archive):

```sh
cmake -S macos -B macos/build-fuzz -DENABLE_FUZZ_TESTS=ON \
  -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++ \
  -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang
cmake --build macos/build-fuzz
ctest --test-dir macos/build-fuzz -L fuzz --output-on-failure
```

Each fuzz harness runs for `FUZZ_DURATION_SEC` seconds (30 by default;
override via `-DFUZZ_DURATION_SEC=N`). For a longer soak against one harness:

```sh
./macos/build-fuzz/fuzz_decodeRectPayload -max_total_time=600 -print_final_stats=1
```

## Running UI tests in a VM (recommended)

Running UI tests in a VM lets you keep using your Mac while the suite executes.
The repo includes a bootstrap script that sets up a Parallels macOS guest in
about 30 minutes (mostly Xcode download time).

### One-time VM setup

1. **Create the VM in Parallels Desktop.** New → Install macOS [latest]. Give
   it 4 cores and 8 GB RAM. Sign in with your Apple ID, skip optional
   onboarding (Siri / location / screen time).

2. **Install Xcode** in the guest from the App Store (~30 GB download). Open
   it once to accept the license. Then in a guest Terminal:

   ```sh
   sudo xcodebuild -runFirstLaunch
   sudo xcodebuild -license accept
   ```

3. **Share your host's GitHub directory into the guest.** In Parallels VM
   Settings → Sharing → Custom Folders, share the parent directory containing
   both `NPP_HexEdit` and `nextpad-plus-plus`. The guest sees them under
   `/Volumes/My Shared Files/...`.

4. **Run the bootstrap script** once in the guest (it auto-detects the shared
   folder, installs Homebrew + xcodegen + cmake + git, builds the plugin to a
   VM-local directory for speed, runs the unit + smoke tiers, and writes
   `~/.npp-hexedit-vm.env` with the discovered paths):

   ```sh
   "/Volumes/My Shared Files/.../NPP_HexEdit/macos/scripts/vm-bootstrap.sh"
   ```

5. **Grant Accessibility permission to Xcode** in the guest's
   System Settings → Privacy & Security → Accessibility (same as the host
   pre-flight above).

6. **Grant Accessibility permission to the test runner on its first run.**
   Run `~/vm-test-local.sh` once with the VM's desktop visible. macOS will
   show a one-time prompt for `HexEditorUITestRunner` — click "Allow",
   then verify the entry is checked in System Settings → Privacy & Security
   → Accessibility. Subsequent runs are unattended (the script preserves
   DerivedData so the runner's ad-hoc code hash stays stable, which keeps
   the TCC grant valid). If you see "Timed out while enabling automation
   mode" in the test log, the grant was lost — repeat this step. Pass
   `--clean` to vm-test-local.sh to force a DerivedData wipe (you'll need
   to re-grant after).

### Daily UI test runs

Inside the guest, after a host-side edit:

```sh
~/vm-test-local.sh \
  -only-testing:HexEditorUITests/HexEditorUITests/<test-name>
```

`vm-test-local.sh` is a copy of `macos/scripts/vm-test.sh` you make once
(`cp /Volumes/My\ Shared\ Files/.../NPP_HexEdit/macos/scripts/vm-test.sh ~/vm-test-local.sh && chmod +x ~/vm-test-local.sh`).
The local copy avoids a Parallels SMB caching quirk where bash reads the
shared script with stale content even after the host edits it.

The script: rebuilds the plugin; rsyncs `--checksum` the test source from the
shared folder to a VM-local mirror (so xcodebuild compiles from VM-local
files, sidestepping the SMB-caching quirk where swiftc would see stale
content); runs xcodebuild from there; and copies the result bundle + Markdown
summary back to the shared folder so you can read them on the host. By
default DerivedData is preserved between runs so the test runner's ad-hoc
code hash stays stable and TCC's Accessibility grant survives. Pass
`--clean` to wipe DerivedData (and re-grant the runner's Accessibility
permission afterward).

You can also drive everything via SSH from the host:

```sh
# In ~/.ssh/config on the host:
#   Host npp-vm
#       HostName <vm-name-or-ip>.local
#       User <vm-username>
#       IdentityFile ~/.ssh/npp_vm
#       ControlMaster auto
#       ControlPath ~/.ssh/cm-%r@%h:%p
#       ControlPersist 600

ssh npp-vm "~/vm-test-local.sh -only-testing:..."
cat macos/ui-tests-xcode/build/test-results.md   # read summary on host
```

## Adding a language

The user-facing instructions live in [README.md](README.md). The summary for
contributors: drop a `Localizable.<lang>.strings` file in
`macos/resources/`, register it in `macos/CMakeLists.txt`'s
`HEX_LOCALIZATION_FILES` list, and reinstall. Use the existing
`Localizable.en.strings` as the template; partial regional override files
(like the shipped `Localizable.en-GB.strings`) are also supported.

The cascade lookup that picks which file's text to display lives in
`hexUserPreferredLanguages()` in [macos/src/HexEditor.mm](macos/src/HexEditor.mm).
It reads the user's preferred-languages list via `CFPreferencesCopyAppValue`
rather than `[NSLocale preferredLanguages]` — see gotcha #2 below for why.

### How the test suite drives the cascade

The XCTest cascade cases (`testLocalizationCascadeBritishEnglish`, etc.)
need to launch the host with a specific language preference active. They do
that by setting an environment variable:

```swift
app.launchEnvironment = ["HEX_EDITOR_LANG_OVERRIDE": language]
```

The plugin checks this env var *first* in `hexUserPreferredLanguages()`, so
the test's chosen language wins regardless of system settings. Two
"obvious" alternatives don't work — keep them in mind if you write similar
infrastructure:

- **`defaults write org.nextpadplusplus.mac AppleLanguages`** from inside the
  XCUI runner gets silently redirected into the runner's sandbox container.
  Nextpad++ launches outside the sandbox and reads the *real* prefs (which
  don't have your override).
- **`-AppleLanguages '(de)'` on the command line** sets the locale fine, but
  Nextpad++ also tries to open `(de)` as if it were a file path. That fails
  loudly and prevents the normal "open with one empty buffer" startup.

The env var sidesteps both problems.

## Gotchas / things to watch out for

Six non-obvious things that have eaten hours of debugging time. Each entry
starts with a one-line summary; the detail explains the *why* so you can
recognise the same shape of bug if it shows up somewhere new.

1. **In tests, Scintilla doesn't get keystrokes until you click it.**
   When the host runs an action like Edit > Paste from a menu, macOS leaves
   the keyboard focus on the surrounding `SplitGroup` view, not on Scintilla
   itself. After that, a Cmd+A or Edit > Select All looks like it ran but
   actually does nothing — no view in the focus chain handles `selectAll:`,
   so the menu item is even disabled. UI tests fix this by explicitly
   clicking the Scintilla view first to make it the first responder. The
   helper `focusScintilla(in:)` in the test suite does that.

2. **`[NSLocale preferredLanguages]` lies if the host doesn't ship your
   language.** macOS filters that API against the host's installed
   localization folders (`.lproj`). Nextpad++ ships only `en.lproj`, so
   `NSLocale` silently drops user preferences for `de`, `en-GB`, anything
   else. Read the raw user list with `CFPreferencesCopyAppValue` instead.

3. **In tests, `typeKey` and `typeText` don't reach Scintilla — even with
   focus.** Scintilla's `keyDown:` doesn't pick up the synthetic events the
   XCUI runner sends. There's no fix; for tests, drive Scintilla through
   Edit-menu actions (Paste, Select All) instead of through the keyboard.

4. **Parallels shared folders serve stale content sometimes.** You edit a
   file on the host; from inside the guest, `grep`/`sed`/`cat` see the new
   content but `bash` running the same file as a script reads stale content
   from a different cache layer. Workarounds:
   - `scp` (or git push/pull) host edits into the guest's local filesystem
     when you need guaranteed-fresh content — this is the bulletproof path.
   - Run `vm-test.sh` from a guest-local copy (`~/vm-test-local.sh`), not
     from the share. Bash executing a script is the most cache-prone path.
   - To force-refresh an existing file across the share, delete and recreate
     it on the host. The new inode looks like a new file to SMB, bypassing
     the cache entirely.

5. **xcodebuild's incremental cache trusts file modification times — and
   gotcha #4 messes with those.** Result: edits to test source occasionally
   don't show up in the rebuilt test bundle. `vm-test.sh` deletes the
   relevant DerivedData directory before each run for this reason. Costs
   ~30-60s per run; prevents the entire "I edited the test, why didn't it
   pick up?" class of confusion.

6. **`defaults write` from inside the XCUI runner doesn't touch real prefs.**
   The runner is sandboxed; any prefs write (whether via shelling out to
   `/usr/bin/defaults` or via NSUserDefaults APIs) gets redirected into
   `~/Library/Containers/<runner-bundle-id>/Data/Library/Preferences/`.
   Nextpad++ launches *outside* that sandbox and reads the real prefs file,
   so the override never lands. For any per-test setting, use
   `XCUIApplication.launchEnvironment` (an env var) instead.

## Editing the plugin source

The plugin is two files plus a header: an Objective-C++ adapter
([macos/src/HexEditor.mm](macos/src/HexEditor.mm)) and a pure-logic core
([macos/src/core/](macos/src/core/)). Where to put new code:

- **Logic that doesn't need macOS or Nextpad++ APIs** → write it in `HexCore`
  and add a unit test in `HexCoreTests.cpp`. The adapter calls your new
  function, takes the `ByteEditOperation` it returns, and applies the change
  to the underlying editor as a single undo step.
- **Anything UI-related** (a new dialog, menu item, view, keyboard shortcut)
  → write it in `HexEditor.mm`. If it produces state worth checking from a
  test, expose it through the diagnostic accessibility element
  (`hex-editor.cursor.diagnostic`) so the test suite can read it.
- **A new top-level menu entry under Plugins → HexEditor** → register it in
  the plugin's `setInfo` function (which sets the menu count and the title
  of each entry), then update `HexEditorPluginSmokeTests` so it asserts the
  new count and title.
- **Localized strings with two or more parameters** → use numbered
  positional placeholders (`%1$d`, `%2$@`, ...). Bare `%d`/`%@` repeated
  prevents translators from reordering for languages where parameters
  naturally appear in a different sequence. If the call site needs dynamic
  width (e.g. `%0*zx`), pre-format that argument into an `NSString *` at
  the call site and pass it as a simple `%1$@` so translators don't have
  to know printf's dynamic-width syntax. The grep
  `grep -E '"[^"]+"\s*=\s*"[^"]*%[^1-9$%][^%]*%[^1-9$]' Localizable.*.strings`
  finds violators.

### Rectangular (block) selection internals

Three layers, mirrored across `HexCore` and `HexEditor.mm`:

- **Geometry** — `hexedit::RectSelection` carries `originOffset`, `width`,
  `height`, and the `bytesPerRow` it was anchored to. Pure helpers
  (`makeRectSelection`, `rectToRanges`, `extractRectBytes`) live in
  `HexCore` and are unit-tested. The "anchored to bytesPerRow" field is
  the load-bearing invariant: any code path that changes `currentBytesPerRow()`
  (Columns dialog, View-in submode, hex-view toggle) must call
  `clearRectSelection()` because the rect's column coordinates no longer
  map to the same bytes on screen.
- **Interaction** in `HexEditor.mm` — `mouseDown:` / `mouseDragged:` /
  `mouseUp:` branch on a modifier match against `currentRectModifierFlags()`
  (Option or Shift+Option, per Options dialog). Drags only originate in
  the hex byte or ASCII pane; clicks on the address column toggle a
  bookmark on the row regardless of modifier. `keyDown:` matches
  Shift+modifier+arrow before the plain-arrow switch and bootstraps a 1×1
  rect at the caret on first use. Plain arrows / typing /
  `clearAllByteSelections()` collapse the rect.
- **Clipboard** — every rect copy emits two pasteboard items: a
  public-text fallback (space-separated hex bytes per row, joined by
  `\n`) for cross-app use, plus a custom UTI
  `org.notepad-plus-plus.HexEditor.rectangular` that carries a 20-byte
  header (`HXR1` magic, version, kind, width, height, dataLength)
  followed by the raw bytes. Paste reads the custom UTI first
  (preserving shape and source-pane kind), falling back to
  `parseRectClipboardText` on the public-text payload when no custom UTI
  is present. `kind = Bytes` and `kind = Ascii` are interchangeable
  since both carry the same byte data with different display
  interpretations — the address column is not selectable, so address-source
  clipboards do not exist. Strict shape-match — `dest.width × dest.height`
  must equal payload `width × height` — is enforced before any byte is
  written.

The diagnostic AX value (`hex-editor.cursor.diagnostic`) exposes
`rectActive`, `rectOrigin`, `rectWidth`, `rectHeight`, `rectBpr`, and
`rectOriginPane` so XCUI tests can verify rect state structurally rather
than via fragile drag mechanics. The Swift parser in
[macos/ui-tests-xcode/Tests/HexEditorUITests.swift](macos/ui-tests-xcode/Tests/HexEditorUITests.swift)
reads these into `HexCursorState` for assertion.

## Releasing

See [CHANGELOG.md](CHANGELOG.md) for the release-notes structure (current
shape: a v1.x.x heading, sub-sections for "What's new" / tests added /
divergence updates). Each release entry documents shipped behavior,
divergences from the Windows baseline, and the test tiers' state at release
time. Bump `project(... VERSION x.y.z ...)` in
[macos/CMakeLists.txt](macos/CMakeLists.txt) before tagging.

## License

GPLv2, inherited from the original Jens Lorenz source. See
[HexEditor/license.txt](HexEditor/license.txt).
