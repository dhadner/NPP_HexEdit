# NPP_HexEdit

A hex editor plugin for Notepad++.

This repo holds two versions of the same plugin:

- **The original Windows version** (`HexEditor/`) — Jens Lorenz's HEX-Editor
  v0.9.x, copied without changes from
  [SourceForge](https://sourceforge.net/projects/npp-plugins/files/Hex%20Editor/).
- **A macOS port** (`macos/`) — a fresh rewrite that runs as a plugin file
  (`HexEditor.dylib`) inside [Notepad++ macOS](https://github.com/notepad-plus-plus-macos).
  ".dylib" is just the macOS file extension for a dynamically loaded library;
  Notepad++ loads it on launch.

## Features (macOS port v1.0.0)

| Area | Capability |
| --- | --- |
| Editing | Direct byte overwrite + append in hex and ASCII panes; bit-precise editing in binary notation |
| Clipboard | Copy / Cut / Paste with Windows-faithful semantics — Copy emits hex string text, Copy Binary emits raw bytes |
| View modes | 8/16/32/64-bit grouping, hex/binary notation, big/little-endian display order, configurable address width and columns |
| Search | Find, Find and Replace, Find Next/Previous (Cmd+F / Cmd+G / Cmd+Shift+G); auto-detects ASCII vs hex byte patterns |
| Navigation | Go to Offset (Cmd+L) — accepts decimal, `0x`-prefixed hex, and relative `+`/`-` offsets |
| Compare | Compare HEX against any file — differing bytes highlighted in red; one click clears the result |
| Pattern | Insert Columns (inject a hex pattern into every row) and Pattern Replace (fill the selection with a repeating pattern) |
| Zoom | Cmd+Scroll or two-finger trackpad pinch resizes the hex font (matches Scintilla's behavior in the host's text views) |
| Persistence | View mode, address width, columns, find options persist via `NSUserDefaults` (`org.notepad-plus-plus.HexEditor`) |
| Localization | English (en, en-GB, en-US) and German (de) shipped; add a new language by translating `Localizable.<lang>.strings` |
| Appearance | Semantic `NSColor` values throughout — dark mode and accent-colour preferences inherit from the host |

The full feature inventory and divergences from the Windows version are tracked in [CHANGELOG.md](CHANGELOG.md).

## Install (macOS)

You build the plugin from source, then install it. Three steps:

```sh
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release   # set up the build
cmake --build macos/build-universal                                   # compile
cmake --install macos/build-universal                                 # copy the result into place
```

The install step copies the plugin and its language files to:

```text
~/.notepad++/plugins/HexEditor/
```

Restart Notepad++ macOS. You'll see a new **Plugins → HEX-Editor** submenu with six entries:
View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, and Help.

The build expects to find a checkout of `notepad-plus-plus-macos` next to this
repo (so they share a parent folder). If yours lives somewhere else, pass
`-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` on the first `cmake -S …`
line above. [DEVELOPER.md](DEVELOPER.md) covers this in more detail.

## Adding a language

The plugin's text (menus, dialogs, error messages) lives in files named
`Localizable.<lang>.strings` next to the plugin file. The `<lang>` part is a
[BCP 47](https://datatracker.ietf.org/doc/html/rfc5646) language tag like
`de` (German), `de-AT` (Austrian German), `en-GB` (British English),
`zh-Hans` (Simplified Chinese), and so on.

**To add a brand new language**, copy
`macos/resources/Localizable.en.strings` to `Localizable.<lang>.strings`,
translate the right-hand side of every line, add the new file to
`HEX_LOCALIZATION_FILES` in `macos/CMakeLists.txt`, and reinstall.

**To override just a few words for a regional variant** (say British English
vs. American English), create `Localizable.en-GB.strings` containing only
the keys you want to change. Anywhere you don't override, the plugin falls
back to the base language. So if `en.strings` says "color" and you only want
British "colour" in one place, your `en-GB.strings` only needs that one line:

```text
/* Localizable.en-GB.strings — overrides only */
"compare.summaryDifferPlural" = "%d bytes differ. (Use Clear Compare Result to remove the highlight.)";
```

**How the plugin picks which language to show.** It reads your Mac's
preferred-languages list and walks it in order. For each language it tries
the exact tag first, then the base (so `en-GB` is checked before `en`).
Example with your preferred languages set to `["en-GB", "de"]`:

| Layer | The plugin looks here first… | …then falls back to |
| --- | --- | --- |
| 1 | `Localizable.en-GB.strings` (your overrides) | layer 2 |
| 2 | `Localizable.en.strings` (the base English file) | layer 3 |
| 3 | `Localizable.de.strings` (full German translation) | layer 4 |
| 4 | English text built into the plugin itself | (last resort) |

**To try out a language without changing your whole Mac's settings**, override
it on Notepad++ macOS only:

```sh
defaults write org.notepadplusplus.mac AppleLanguages -array de
# put it back when you're done:
defaults delete org.notepadplusplus.mac AppleLanguages
```

(For the curious: the plugin uses `CFPreferencesCopyAppValue` rather than
`[NSLocale preferredLanguages]` to read your preferences. That's because
macOS filters `NSLocale` against the languages the host app ships, and
Notepad++ macOS ships only English — so `NSLocale` would silently drop your
choice. `CFPreferencesCopyAppValue` returns it unfiltered. See
[DEVELOPER.md](DEVELOPER.md) for more.)

## Tests

There are three sets of tests, ordered from fastest to slowest:

```sh
# Fast tests — the plugin's pure logic + a quick "does it load?" check.
# Takes about half a second, no Notepad++ required.
ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure

# Slow tests — drives the real Notepad++ app through its UI. ~14 minutes.
# Needs Notepad++.app installed (or built from source).
macos/ui-tests-xcode/run-tests.sh
```

Every UI test run writes a Markdown summary at
`macos/ui-tests-xcode/build/test-results.md` so you can see what passed and
failed without scrolling through pages of xcodebuild output.

The UI tests take over your keyboard and mouse for the duration. If you want
to keep working while they run, [DEVELOPER.md](DEVELOPER.md) walks through
running them inside a Parallels virtual machine instead.

## Project layout

```text
.
├── HexEditor/                 — original Windows source (Jens Lorenz, 2006). Unchanged.
├── macos/                     — macOS port
│   ├── src/                   — HexEditor.mm (AppKit/NPP adapter) + core/HexCore.* (pure logic)
│   ├── tests/                 — HexCoreTests (unit) + HexPluginSmokeTests (dlopen)
│   ├── ui-tests-xcode/        — XCTest UI suite (XcodeGen-generated)
│   ├── resources/             — Localizable.{en,en-GB,en-US,de}.strings
│   ├── scripts/               — vm-bootstrap.sh + vm-test.sh (Parallels UI test workflow)
│   └── CMakeLists.txt         — build, install, test wiring
├── CHANGELOG.md               — release notes
├── DEVELOPER.md               — build, test, and contribute
└── README.md                  — this file
```

## Build status (Windows, upstream)

[![Build status](https://github.com/chcg/NPP_HexEdit/actions/workflows/CI_build.yml/badge.svg)](https://github.com/chcg/NPP_HexEdit/actions/workflows/CI_build.yml)

## Related repos

- [chcg/NPP_HexEdit](https://github.com/chcg/NPP_HexEdit) — the upstream Windows mirror this fork is based on
- [JetNpp/HexEditor](https://github.com/JetNpp/HexEditor)
- [mackwai/NPPHexEditor](https://github.com/mackwai/NPPHexEditor)

## License

GPLv2, inherited from the original Jens Lorenz source. See [HexEditor/license.txt](HexEditor/license.txt).
