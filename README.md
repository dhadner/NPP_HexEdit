# NPP_HexEdit

A hex editor plugin for Nextpad++.

This repo holds the MacOS port of the Windows Notepad++ HEX-Editor plugin.  The original Windows source code is included under the same GPL license for comparison since this is a fork of that repo.

In this repo are:

- **The original Windows version** (`HexEditor/`) — Jens Lorenz's HexEditor
  v0.9.x, from
  [SourceForge](https://sourceforge.net/projects/npp-plugins/files/Hex%20Editor/) and forked from the unofficial GitHub repo at [GitHub](https://github.com/chcg/NPP_HexEdit).
- **A macOS port** (`macos/`) — a fresh rewrite that runs as a plugin file
  (`HexEditor.dylib`) inside [Nextpad++](https://github.com/notepad-plus-plus-macos).
  ".dylib" is just the macOS file extension for a dynamically loaded library;
  Nextpad++ loads it on launch.

## Features (macOS port v1.1.0)

| Area | Capability |
| --- | --- |
| Editing | Direct byte overwrite + append in hex and ASCII panes; bit-precise editing in binary notation |
| Linear clipboard | Copy / Cut / Paste with Windows-faithful semantics — Copy emits hex string text, Copy Binary emits raw bytes; Paste auto-detects |
| Rectangular (block) selection | Option-drag (or Shift+Option, configurable in Options) draws a 2D rectangle in the hex bytes or ASCII columns. Shift+Option+arrows extend it. Cut / Copy / Paste / Delete work on the rectangle as a unit; Pattern Replace fills it row-by-row with the pattern restarting at each row's first byte |
| Strict-shape paste | Rectangular paste only lands when the destination is also a rect of the exact same width × height; mismatch shows a clarifying dialog. A custom pasteboard type carries shape + source-pane kind so copy-then-paste round-trips preserve geometry |
| Multi-GB clipboard | Copy / paste of multi-gigabyte hex selections doesn't serialise the buffer into pasteboard bytes — the plugin promises the data via `NSPasteboardTypeOwner` and materialises lazily on consumer request (or at quit time, after a Word-style "keep clipboard contents?" prompt above 16 MB). Find / Compare / rectangular paste iterate via 256 KB `ByteSource` chunks straight off Scintilla, so RAM use is O(window) not O(file) |
| Cross-app paste | Strips the address column and ASCII gloss from clipboard text emitted by lldb (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA, C-string escape sequences (`\x48\x65...`), and C array literals — the data lands cleanly |
| View modes | 8/16/32/64-bit grouping, hex/binary notation, big/little-endian display order, configurable address width (4–16 digits) and columns (1..128/bytes-per-cell) |
| Search | Find, Find and Replace, Find Next/Previous (Cmd+F / Cmd+G / Cmd+Shift+G); auto-detects ASCII vs hex byte patterns |
| Navigation | Go to Offset (Cmd+L) — accepts decimal, `0x`-prefixed hex, and relative `+`/`-` offsets. Cmd+Home / Cmd+End to document edges; Shift+Cmd+arrow extends selection by line / to document edges. Bare arrows scroll the viewport so the cursor never walks off-screen; asymmetric Left / Right byte-stride matches Windows |
| Compare | Compare HEX against any file — differing bytes highlighted in red; one click clears the result |
| Pattern | Insert Columns (inject a hex pattern into every row) and Pattern Replace (fill the selection with a repeating pattern; works on linear and rectangular selections) |
| Mirror cursor | Inactive pane (hex or ASCII) shows the byte/character at the cursor as a 2px underline by default, or as a full rectangle when the Mirror toggle is enabled in Options |
| Zoom | Cmd+Scroll or two-finger trackpad pinch resizes the hex font (matches Scintilla's behavior in the host's text views) |
| Options | Plugin-wide preferences dialog (Plugins → HexEditor → Options...): rectangular-selection modifier (Option vs Shift+Option), mirror-cursor toggle (rectangle vs underline). Designed to grow without churning the main menu |
| Persistence | View mode, address width, columns, find options, rect-modifier choice, mirror toggle, and per-buffer hex view intent persist via `NSUserDefaults` (`org.notepad-plus-plus.HexEditor`) |
| Localization | 15 `.strings` files cover 11 full translations (English, German, Spanish, French, Italian, Polish, Russian, Ukrainian, Simplified Chinese, Hebrew, Arabic) plus 4 regional overrides (British / American English, Peninsular / Mexican Spanish). Cascade falls through exact tag → base tag → next preferred language → embedded English defaults. Every format placeholder is numbered (`%1$@`, `%1$d`, ...) so translators learn one rule. See [LOCALIZATION.md](LOCALIZATION.md) for the translator-facing guide |
| RTL languages | Menus / dialogs / host chrome auto-flip under Hebrew and Arabic. The hex view itself stays LTR (Offset on the leading-physical edge, ASCII on the trailing) — hex dumps are universally LTR even for RTL-language developers, so flipping would break the canonical form |
| Appearance | Semantic `NSColor` values throughout — dark mode and accent-colour preferences inherit from the host |

The full feature inventory and intentional divergences from the Windows version are tracked in [CHANGELOG.md](CHANGELOG.md).

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

NOTE: The app name is expected to change as the rebranding from Notepad++ for macOS to Nextpad++ is completed.  The rebranding is not expected to affect this plugin as the name change has already been made throughout.

Restart Nextpad++. You'll see a new **Plugins → HexEditor** submenu with seven entries:
View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Options, and Help.

The build expects to find a checkout of `notepad-plus-plus-macos` next to this
repo (so they share a parent folder). If yours lives somewhere else, pass
`-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` on the first `cmake -S …`
line above. [DEVELOPER.md](DEVELOPER.md) covers this in more detail.

## Adding a language

See [LOCALIZATION.md](LOCALIZATION.md) for the full translator-facing
guide — file format, the regional cascade, placeholder rules, and how
to test a new language locally without changing your Mac's system
preferences.

The short version: the plugin's text (menus, dialogs, error messages)
lives in files named `Localizable.<lang>.strings` next to the plugin
file, where `<lang>` is a [BCP 47](https://datatracker.ietf.org/doc/html/rfc5646)
tag like `de` (German), `en-GB` (British English), `zh-Hans` (Simplified
Chinese). Copy `macos/resources/Localizable.en.strings`, translate the
right-hand side of every line, add the file to `HEX_LOCALIZATION_FILES`
in `macos/CMakeLists.txt`, and reinstall.

The plugin reads your Mac's preferred-languages list in order; for
each language it tries the exact tag first, then the base, then moves
on. Last resort is English compiled into the plugin itself. The About
dialog shows which `.strings` file the runtime is using and links to
the translator guide for users whose language isn't yet supported.

## Tests

Five tiers, from fastest to slowest. Live status of the most recent developer-machine run is published at [docs/test-status.md](docs/test-status.md) — the dashboard is regenerated by the pre-commit script and committed to the repo. There's no CI equivalent because the UI tier needs a Parallels VM that GitHub-hosted runners can't provide.

1. **Unit tests** — pure C++ exercising cursor math, edit planning, clipboard parsing, and pattern operations without touching Nextpad++ or AppKit. ~9,200 assertions across 37 suites, milliseconds. `ctest -L unit`.
2. **Unit tests under ASan + UBSan** — same suite rebuilt with AddressSanitizer + UndefinedBehaviorSanitizer to catch memory-safety and signed-overflow bugs the release build would silently tolerate. Sub-second.
3. **Plugin smoke tests** — `dlopen`s the built dylib and asserts the NPP exports, the menu shape, and the English titles. Sub-second. `ctest -L smoke`.
4. **Fuzz / robustness** — eight libFuzzer harnesses against every external-input parser the plugin exposes (rectangular-clipboard path × 4, cross-app paste cleaner, Find/Replace pattern parser, linear hex-clipboard parser, Goto-Offset expression parser). 30 s each, ~4 minutes total under ASan + UBSan. `ctest -L fuzz`.
5. **XCTest UI** — full suite against the running Nextpad++.app. Toggle, undo/redo, clipboard round-trips (linear and rectangular, including 1.5 GB scale), all dialog flows, bit-precise editing, the localization cascade for all 15 shipped tags, and more. ~46 minutes on a Parallels VM. `ctest -L ui`. The suite locks the host keyboard and mouse for the duration, so [DEVELOPER.md](DEVELOPER.md) walks through running it inside a Parallels VM instead.

The pre-commit gate runs all five tiers in fastest-first order:

```sh
bash macos/scripts/pre-commit-tests.sh
```

Tiers 1–4 run on the host (~4 min total); tier 5 SSH-routes to the Parallels VM. Each tier's full output is preserved at `/tmp/pre-commit-tests-<pid>/N-tier.log`, and after the run completes the script regenerates [docs/test-status.md](docs/test-status.md) so the GitHub view always reflects the most recent verified state. For host-only iteration during development, pass `--skip-ui`.

## Project layout

```text
.
├── HexEditor/                 — original Windows source (Jens Lorenz, 2006). Unchanged.
├── macos/                     — macOS port
│   ├── src/                   — HexEditor.mm (AppKit/NPP adapter) + core/HexCore.* (pure logic)
│   ├── tests/                 — HexCoreTests (unit) + HexPluginSmokeTests (dlopen)
│   ├── ui-tests-xcode/        — XCTest UI suite (XcodeGen-generated)
│   ├── resources/             — Localizable.<lang>.strings (15 files: 11 full translations + 4 regional overrides)
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
