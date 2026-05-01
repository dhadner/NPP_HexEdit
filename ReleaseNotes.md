# HEX-Editor for Notepad++ macOS — v1.1.0

The big v1.1.0 addition: full **rectangular (block) selection**, matching the Windows plugin's `eSel::HEX_SEL_BLOCK` capability that v1.0.0 had to leave on the cutting-room floor. Plus a real **Options dialog** (where the rect-modifier preference lives) and a translator-friendly localization pass.

## Highlights

- **Option-drag in the hex pane, ASCII pane, or address column** draws a 2D rectangle. In bytes / ASCII the drag is cell-granular; in the address column it spans whole rows. The modifier is configurable in Options (Option, matching Scintilla / the Windows plugin; or Shift+Option, matching VS Code).
- **Shift+Option+arrow keys** grow / shrink the rectangle. The first such press while no rect exists creates a 1×1 rect at the caret. Plain arrows / typing collapse it.
- **Cut / Copy / Paste / Delete** work on the rectangle as a unit. Copy emits both a public-text fallback (hex per row, or ASCII per row, or address strings joined by newlines, depending on the source pane) and a custom pasteboard type carrying the kind tag plus the rectangle's shape — so paste-back into the plugin preserves geometry. Delete is zero-fill (file size unchanged, offsets preserved).
- **Strict shape-match paste**: pasting a rectangular payload requires the destination to be a rectangle of the exact same width × height. Mismatch shows a clarifying dialog. Address-source clipboards are rejected as "cannot paste as bytes". External text-only clipboards (no custom UTI) are parsed as `\n`-separated rows per the same rules; single-line text falls through to the existing linear paste so cross-app workflows are unaffected.
- **Pattern Replace on a rectangle** fills row-by-row with the pattern restarting at each row's first byte (matches the Windows `eSel::HEX_SEL_BLOCK` semantics). Linear Pattern Replace is unchanged.
- **Options dialog** (Plugins → HEX-Editor → Options...) returns, this time with real settings instead of a stub. Today: rectangular-modifier choice. Designed to grow without churning the main menu.
- **Numbered localized parameters** — every multi-parameter `.strings` key now uses `%1$`, `%2$`, ... so translators can reorder freely. The dynamic-width hex strings in `goto.message` are pre-formatted at the call site so translators see plain `%1$@` / `%2$@` slots.
- **IDE quieter** — `.vscode/c_cpp_properties.json` no longer trips the Microsoft C/C++ extension on the universal build's dual `-arch` flags. clangd users keep their existing `macos/.clangd` setup.

## Install

```sh
cmake -S macos -B macos/build-universal -DCMAKE_BUILD_TYPE=Release
cmake --build macos/build-universal
cmake --install macos/build-universal
```

Restart Notepad++ macOS. The plugin appears as **Plugins → HEX-Editor** with seven entries: View in HEX, Compare HEX, Clear Compare Result, Insert Columns, Pattern Replace, Options, and Help.

The build expects a checkout of `notepad-plus-plus-macos` next to this repo; pass `-DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos` if it lives elsewhere.

## Differences from the Windows version

- v1.1.0 closes v1.0.0's biggest gap — rectangular Pattern Replace now works on macOS with per-row pattern restart matching the Windows semantics.
- The Options dialog scope is plugin behavior (rect modifier), not appearance. Color / font choices remain delegated to the host's `NSAppearance` and Style Configurator.
- All other v1.0.0 divergences (Compare HEX picks a file rather than a second split; lowercase hex copy by default; macOS Help is a simple About dialog; Goto reached via Cmd+L) carry over unchanged. See [CHANGELOG.md](CHANGELOG.md) for the full list.

## Tests

- **HexCore** unit tests — 30 suites, ~750 assertions, runs in milliseconds. New in v1.1.0: rect extract / format / parse coverage including the external-text inbound parser (Q2.b), shape-mismatch rejection, EOF clipping, and CRLF tolerance.
- **Plugin smoke** — dlopen + verify the 7-item menu. ~400 ms.
- **XCTest UI** — full suite against the running app. New: Options dialog opens-and-cancels-cleanly. Diagnostic AX value extended with rect fields so future tests can verify rect state structurally rather than via fragile drag mechanics.

Run the fast pair (`unit | smoke`) with `ctest --test-dir macos/build-universal -L "unit|smoke" --output-on-failure`. Run the UI tier via `macos/ui-tests-xcode/run-tests.sh` (or in a Parallels VM per [DEVELOPER.md](DEVELOPER.md) to avoid locking your keyboard for ~14 minutes).

## Known limitations / planned

- **Rectangular paste at a bare caret** is intentionally not supported in v1.1.0 — the strict-shape rule requires a same-shape destination rect. A future release may add an optional "auto-create destination from clipboard shape at caret" behavior; for now the safer path is the strict rule.
- **Multiple rectangular selections** (Scintilla-style) and **column-mode typing** across a rectangle are not on the v1.1.x roadmap.
- The plugin still tracks Notepad++ macOS upstream API growth — see CHANGELOG for items that depend on host-side plumbing not yet exposed (e.g. comparing two split panes, intercepting `IDM_SEARCH_GOTOLINE`).

## License

GPLv2, inherited from the original Jens Lorenz source. See [HexEditor/license.txt](HexEditor/license.txt).
