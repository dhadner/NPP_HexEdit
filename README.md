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

## Features (macOS port v1.1.0)

| Area | Capability |
| --- | --- |
| Editing | Direct byte overwrite + append in hex and ASCII panes; bit-precise editing in binary notation |
| Linear clipboard | Copy / Cut / Paste with Windows-faithful semantics — Copy emits hex string text, Copy Binary emits raw bytes |
| Rectangular (block) selection | Option-drag (or Shift+Option, configurable in Options) draws a 2D rectangle in hex bytes / ASCII / address columns. Shift+Option+arrows extend it. Cut / Copy / Paste / Delete work on the rectangle as a unit; Pattern Replace fills it row-by-row with the pattern restarting at each row's first byte |
| Strict-shape paste | Rectangular paste only lands when the destination is also a rect of the exact same width × height; mismatch shows a clarifying dialog. Carries a custom pasteboard type so a copy-then-paste round-trip preserves shape and source-pane kind |
| View modes | 8/16/32/64-bit grouping, hex/binary notation, big/little-endian display order, configurable address width and columns |
| Search | Find, Find and Replace, Find Next/Previous (Cmd+F / Cmd+G / Cmd+Shift+G); auto-detects ASCII vs hex byte patterns |
| Navigation | Go to Offset (Cmd+L) — accepts decimal, `0x`-prefixed hex, and relative `+`/`-` offsets |
| Compare | Compare HEX against any file — differing bytes highlighted in red; one click clears the result |
| Pattern | Insert Columns (inject a hex pattern into every row) and Pattern Replace (fill the selection with a repeating pattern; works on linear and rectangular selections) |
| Zoom | Cmd+Scroll or two-finger trackpad pinch resizes the hex font (matches Scintilla's behavior in the host's text views) |
| Options | Plugin-wide preferences dialog (Plugins → HEX-Editor → Options...). Today: rectangular-selection modifier (Option vs Shift+Option). Designed to grow without churning the main menu |
| Persistence | View mode, address width, columns, find options, and the rect-modifier choice persist via `NSUserDefaults` (`org.notepad-plus-plus.HexEditor`) |
| Localization | English (en, en-GB, en-US) and German (de) shipped; add a new language by translating `Localizable.<lang>.strings`. Multi-parameter strings use numbered placeholders so translators can reorder freely |
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

Restart Notepad++ macOS. You'll see a new **Plugins → HEX-Editor** submenu with seven entries:
View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Options, and Help.

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

There are three sets of tests, from fastest to slowest:

1. **Unit tests** — exercise the plugin's pure logic (cursor math, edit
   planning, search, parsing) without touching Notepad++ or any macOS UI.
   Run in milliseconds.
2. **Smoke test** — loads the built plugin file and checks Notepad++ would
   accept it (right exported functions, plugin name, menu entries).
   Runs in well under a second.
3. **UI tests** — launch the real Notepad++ app with the plugin installed
   and drive it with synthetic clicks and keystrokes. ~14 minutes.

The first two are fast and need nothing beyond the build, so they're bundled
into one command. The UI tests are a separate command because they need a
working Notepad++.app and they take over your keyboard and mouse for the
duration:

```sh
# Unit + smoke (the fast pair).
ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure

# UI tests.
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
