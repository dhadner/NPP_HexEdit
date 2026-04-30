# NPP_HexEdit

Notepad++ HEX-Editor plugin — original Windows source preserved alongside a native macOS port.

The Windows source is the upstream HEX-Editor v0.9.x by Jens Lorenz, mirrored unchanged from
[SourceForge](https://sourceforge.net/projects/npp-plugins/files/Hex%20Editor/). The macOS
port lives in [macos/](macos/) and ships as `HexEditor.dylib` for [Notepad++ macOS](https://github.com/notepad-plus-plus-macos).

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
| Persistence | View mode, address width, columns, find options persist via `NSUserDefaults` (`org.notepad-plus-plus.HexEditor`) |
| Localization | English and German shipped; add a new language by translating `Localizable.<lang>.strings` |
| Appearance | Semantic `NSColor` values throughout — dark mode and accent-colour preferences inherit from the host |

The full feature inventory and divergences from the Windows version are tracked in [CHANGELOG.md](CHANGELOG.md).

## Install (macOS)

```sh
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
```

The install copies the dylib and the `Localizable.<lang>.strings` files to:

```text
~/.notepad++/plugins/HexEditor/
```

Restart Notepad++ macOS and the **Plugins → HEX-Editor** submenu appears with six commands:
View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Help.

By default CMake expects a sibling checkout of `notepad-plus-plus-macos` — if it lives elsewhere,
pass `-DNPP_MACOS_DIR=/absolute/path/to/notepad-plus-plus-macos` when configuring.

## Adding a language

The plugin reads `Localizable.<lang>.strings` files installed alongside the dylib. Tags follow
[BCP 47](https://datatracker.ietf.org/doc/html/rfc5646) — `de`, `de-AT`, `en-GB`, `zh-Hans`, etc.

**Full translation.** Copy `macos/resources/Localizable.en.strings` to
`Localizable.<lang>.strings`, translate every right-hand side, then register the new file
in `macos/CMakeLists.txt`'s `HEX_LOCALIZATION_FILES` list and reinstall.

**Regional override (e.g. en-US vs en-GB).** Create
`Localizable.en-GB.strings` containing **only** the keys whose value differs from
`Localizable.en.strings` — for example, anywhere we say "color" you might say "colour".
The lookup walks layers most-specific → most-general, so every key the override file
omits cascades to the base language file, then to the embedded English defaults. No need
to mirror keys you're not changing.

```text
/* Localizable.en-GB.strings — only the overrides */
"compare.summaryDifferPlural" = "%d bytes differ. (Use Clear Compare Result to remove the highlight.)";
```

**Selection.** The plugin consults `[NSLocale preferredLanguages]` in order. For each
preferred language it checks the exact tag *and* its base code. Example with the user's
preferred languages set to `["en-GB", "de"]`:

| Layer | Source |
| --- | --- |
| 1 | `Localizable.en-GB.strings` (overrides only) |
| 2 | `Localizable.en.strings` (the base English) |
| 3 | `Localizable.de.strings` (only used for keys missing from layers 1 + 2) |
| 4 | embedded English defaults compiled into the dylib |

To force a specific language for testing or a one-off run, launch Notepad++ macOS with
the AppleLanguages argument:

```sh
Notepad++.app/Contents/MacOS/Notepad++ -AppleLanguages '(de)'
Notepad++.app/Contents/MacOS/Notepad++ -AppleLanguages '(en-GB)'
```

## Tests

Three tiers — see [macos/TESTING.md](macos/TESTING.md) for full coverage and how each tier maps
to a CTest label.

```sh
# Pure C++ unit + dlopen smoke (fast, no host required)
ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure

# Full XCTest UI suite against Notepad++.app (requires a built host)
macos/ui-tests-xcode/run-tests.sh
```

The XCTest suite force-launches the host with `-AppleLanguages '(en)'` so the English
string assertions stay deterministic regardless of the developer machine's locale.

## Project layout

```text
.
├── HexEditor/                 — original Windows source (Jens Lorenz, 2006). Unchanged.
├── macos/                     — macOS port
│   ├── src/                   — HexEditor.mm (AppKit/NPP adapter) + core/HexCore.* (pure logic)
│   ├── tests/                 — HexCoreTests (unit) + HexPluginSmokeTests (dlopen)
│   ├── ui-tests-xcode/        — XCTest UI suite (XcodeGen-generated)
│   ├── resources/             — Localizable.en.strings + Localizable.de.strings
│   └── CMakeLists.txt         — build, install, test wiring
├── CHANGELOG.md               — release notes
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
