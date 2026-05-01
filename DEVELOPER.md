# Developer guide

How to build, test, and contribute to the macOS port of the Notepad++ HEX-Editor
plugin. If you only want to *use* the plugin, see [README.md](README.md) instead.

## Quick start

```sh
# 1. Clone this repo and the host repo as siblings (any parent directory works
#    — the build only requires they share a parent. Override the discovery path
#    with -DNPP_MACOS_DIR= if you'd rather lay them out differently).
git clone https://github.com/<your-fork>/NPP_HexEdit.git
git clone https://github.com/notepad-plus-plus-macos/notepad-plus-plus-macos.git

# 2. Build the host (one-time; takes a few minutes).
cd notepad-plus-plus-macos
# follow the host's Build-Instructions.md to produce build/Notepad++.app

# 3. Build, install, and smoke-test the plugin.
cd ../NPP_HexEdit
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure
```

If the unit + smoke tiers pass and the host launches with the plugin enabled
(Plugins → HEX-Editor menu present), you have a working dev loop.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| macOS 11+ | Build target | n/a |
| Xcode 15+ | Compiler, SDK, XCTest | App Store, or `xcodes install --latest` |
| Xcode CLT | `xcode-select`, `clang`, `cmake` discovery | `sudo xcode-select --install` |
| Homebrew | Dependency installer | https://brew.sh |
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
│   │   ├── HexEditor.mm       — the macOS-specific code: AppKit UI + Notepad++ glue
│   │   └── core/HexCore.{h,cpp} — pure logic (no UI or editor calls), shared with unit tests
│   ├── resources/             — Localizable.<lang>.strings text files
│   ├── tests/                 — HexCoreTests (logic) + HexPluginSmokeTests (load check)
│   ├── ui-tests-xcode/        — UI test suite that drives the real Notepad++ app
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
[notepad-plus-plus-macos](https://github.com/notepad-plus-plus-macos):

| Need | Required for | Source |
| --- | --- | --- |
| Headers (`NppPluginInterfaceMac.h`, Scintilla `.h`) | Compiling the plugin | Repo source — must be present at `NPP_MACOS_DIR` |
| `Notepad++.app` binary | XCTest UI tier launches it | Either build from source *or* install any compatible binary |

By default CMake looks for the host repo as a sibling directory of `NPP_HexEdit`
— in other words, both repos share the same parent. The parent's name doesn't
matter (`~/src/NPP_HexEdit` next to `~/src/notepad-plus-plus-macos`,
`~/Documents/GitHub/NPP_HexEdit` next to `~/Documents/GitHub/notepad-plus-plus-macos`,
or anything else — only the relative position matters):

```text
<any-parent>/
  NPP_HexEdit/
  notepad-plus-plus-macos/
```

If your layout is different, pass `-DNPP_MACOS_DIR=/abs/path/to/notepad-plus-plus-macos`
on the first `cmake -S macos -B macos/build-universal …` invocation (the
"configure" step that generates the build system; this is separate from
`cmake --build`, which only compiles). Example:

```sh
cmake -S macos -B macos/build-universal \
    -DCMAKE_BUILD_TYPE=Release \
    -DNPP_MACOS_DIR=/Users/me/projects/notepad-plus-plus-macos
```

The path is cached in `macos/build-universal/CMakeCache.txt`, so you only need
to pass it once. Subsequent `cmake --build` runs reuse it.

For the binary, the XCTest tier reads `NPP_MACOS_APP=/abs/path/to/Notepad++.app`
to locate the host. If unset, it defaults to `<NPP_MACOS_DIR>/build/Notepad++.app`
(the build output of the source repo).

**Building the host from source** gives you a guaranteed-compatible binary
matched to the headers your plugin compiled against. Multi-minute build, run
once per host-repo update.

**Using an already-installed `Notepad++.app`** (App Store, GitHub release,
`.dmg`, your own `/Applications/`) is also fine and avoids the host build.
The bundle identifier just needs to be `org.notepadplusplus.mac`. Point the
tests at it:

```sh
NPP_MACOS_APP=/Applications/Notepad++.app macos/ui-tests-xcode/run-tests.sh
```

The risk: if the installed binary was built against a different version of
the NPP plugin API than your headers, the plugin can fail to load at runtime
(symptom: HEX-Editor doesn't appear under the host's Plugins menu). When the
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

# Install to ~/.notepad++/plugins/HexEditor/ (also copies the .strings files).
cmake --install macos/build-universal
```

Faster Apple-Silicon-only build for iteration:

```sh
cmake -S macos -B macos/build-arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Debug
cmake --build macos/build-arm64
```

After install, restart Notepad++ macOS — plugins load on startup.

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

- the five functions Notepad++ expects to find are all there
- `getName()` returns `"HEX-Editor"`
- the right number of menu items are registered, with the expected English titles

The test forces the plugin to use English so the title assertions don't depend
on your Mac's language setting. Run it via:

```sh
ctest --test-dir macos/build-universal -L smoke --output-on-failure
```

### Tier 3 — XCTest UI (~14 min for full suite, ~30s per single test)

The full end-to-end test: launches the real Notepad++ app with the plugin
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
2. Quit any other running `Notepad++.app` (the suite skips itself if a
   different bundle at `org.notepadplusplus.mac` is already running, since
   `XCUIApplication(url:)` cannot launch a second instance under the same
   bundle ID).
3. Grant Accessibility permission to Xcode in
   System Settings → Privacy & Security → Accessibility. XCUITest synthesizes
   keyboard/mouse events through this permission. If tests time out at
   "Setting up automation session", run `tccutil reset Accessibility com.apple.dt.Xcode`
   and re-grant.

**The UI tier locks your keyboard and mouse for the duration of the run** —
~14 min for the full suite. The next section describes how to avoid this.

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
   both `NPP_HexEdit` and `notepad-plus-plus-macos`. The guest sees them under
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

The script: rebuilds the plugin, wipes `~/Library/Developer/Xcode/DerivedData/HexEditorUITests-*`
(needed because SMB mtime staleness confuses xcodebuild's incremental
compiler), runs xcodebuild against a VM-local mirror of the test source, and
copies the result bundle + Markdown summary back to the shared folder so you
can read them on the host.

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

- **`defaults write org.notepadplusplus.mac AppleLanguages`** from inside the
  XCUI runner gets silently redirected into the runner's sandbox container.
  Notepad++ launches outside the sandbox and reads the *real* prefs (which
  don't have your override).
- **`-AppleLanguages '(de)'` on the command line** sets the locale fine, but
  Notepad++ also tries to open `(de)` as if it were a file path. That fails
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
   localization folders (`.lproj`). Notepad++ ships only `en.lproj`, so
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
   Notepad++ launches *outside* that sandbox and reads the real prefs file,
   so the override never lands. For any per-test setting, use
   `XCUIApplication.launchEnvironment` (an env var) instead.

## Editing the plugin source

The plugin is two files plus a header: an Objective-C++ adapter
([macos/src/HexEditor.mm](macos/src/HexEditor.mm)) and a pure-logic core
([macos/src/core/](macos/src/core/)). Where to put new code:

- **Logic that doesn't need macOS or Notepad++ APIs** → write it in `HexCore`
  and add a unit test in `HexCoreTests.cpp`. The adapter calls your new
  function, takes the `ByteEditOperation` it returns, and applies the change
  to the underlying editor as a single undo step.
- **Anything UI-related** (a new dialog, menu item, view, keyboard shortcut)
  → write it in `HexEditor.mm`. If it produces state worth checking from a
  test, expose it through the diagnostic accessibility element
  (`hex-editor.cursor.diagnostic`) so the test suite can read it.
- **A new top-level menu entry under Plugins → HEX-Editor** → register it in
  the plugin's `setInfo` function (which sets the menu count and the title
  of each entry), then update `HexEditorPluginSmokeTests` so it asserts the
  new count and title.

## Releasing

See [CHANGELOG.md](CHANGELOG.md) for the v1.0.0 release notes structure. Each
release entry documents shipped behavior, divergences from the Windows
baseline, and the test tiers' state at release time.

## License

GPLv2, inherited from the original Jens Lorenz source. See
[HexEditor/license.txt](HexEditor/license.txt).
