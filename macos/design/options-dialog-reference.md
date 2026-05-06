# HexEditor Options dialog — design reference

**Status:** Truth model for the macOS Options dialog implementation. Pasted by the user 2026-05-02 from the Windows HexEditor plugin's Options dialog. We don't have the original PNGs (Claude session memory only); the textual transcriptions below are the canonical record.

**Lifetime:** Keep this file until the macOS implementation is approved and a UI test pins the layout. Once the test exists, this doc can be deleted — the test becomes the truth.

**Window title:** `Hex-Editor Options`

**Tabs (left → right):** Start Layout, Startup, Colors, Font

**Buttons (bottom-right of every tab):** `Ok` (default, keyEquivalent Return), `Cancel` (keyEquivalent Escape)

The macOS dialog also has `Apply` and `Reset to Defaults` (already implemented). Keep those — they're useful and don't conflict with the Windows reference.

---

## Tab 1: Start Layout

Three radio-button groups in a single horizontal row, then two labelled numeric fields below.

### Row 1 — three radio groups, side by side

| Group | Options (selected by default in **bold**) | Maps to |
| --- | --- | --- |
| Bits per cell | **8-Bit**, 16-Bit, 32-Bit, 64-Bit | `g_bytesPerCell` (1, 2, 4, 8) |
| Number base | **Hexadecimal**, Binary | `currentViewMode().mode` (Hex / Binary) |
| Endianness | **Big-Endian**, Little-Endian | `g_littleEndian` (false / true) |

Endianness group is disabled when 8-Bit is selected (single byte = no endianness).

### Row 2 — two integer fields

| Label | Default | Range | Maps to |
| --- | --- | --- | --- |
| `Column Count:` | 16 | 1 — `columnsLimitForBytesPerCell(g_bytesPerCell)` (depends on bytes-per-cell, max 128 bytes/row) | `g_columns` |
| `Address Width:` | 8 | 4 — 16 (`HEX_MIN_ADDRESS_WIDTH` / `HEX_MAX_ADDRESS_WIDTH`) | `g_addressWidth` |

Right-aligned text fields, ~60pt wide. Numeric formatter; reject non-integer input.

---

## Tab 2: Startup

Two settings, stacked vertically.

### Field 1 — Extensions

- Label: `Extensions:`
- Right of label, italic / hint text: `e.g.: .dat`
- Single-line text field, full width.
- Pref: comma-or-space-separated list of file extensions (with leading `.`) for which the hex view auto-engages on `NPPN_BUFFERACTIVATED`.
- Empty string → auto-engage disabled (default).

### Field 2 — Control char count threshold

- Label: `Control char count in %`
- Small numeric text field on the right, ~50pt wide.
- Pref: percentage threshold. If a buffer's control-character density exceeds this, auto-engage hex view even if extension doesn't match.
- Default: 30% (or whatever the Windows plugin uses; verify when implementing).
- Empty / 0 → threshold disabled.

Both controls implement the auto-engage feature gated on `NPPN_BUFFERACTIVATED`.

---

## Tab 3: Colors

5-row table with two columns of color wells.

| Row label | Text color (foreground) | Back color (background) |
| --- | --- | --- |
| `Regular Text:` | dark (≈ black) | white |
| `Selection:` | white | light blue/purple (≈ #B0B5FF) |
| `Compare:` | white | pink (≈ #FFA0A0) |
| `Bookmark:` | white | red (≈ #FF0000) |
| `Current Line:` | (no foreground; field empty) | light gray (≈ #E0E0E0) |

Column headers above the wells: `Text`, `Back`.

Notes:

- "Current Line" has no foreground field — only the row's background tints under the cursor.
- All defaults shown above are the Windows defaults; the macOS plugin should pick equivalents that work in both light and dark mode (use `NSColor.textColor` / `NSColor.selectedTextBackgroundColor` / etc. as the dynamic-color baseline; let the Color picker override).
- Each color well is a small dropdown-ish well — clicking opens the standard color picker.
- **Appearance integration:** plugin follows NPP's app-wide Light/Dark setting (`NSApp.appearance` driven by `NppThemeManager`). No plugin-local override — see `feedback_no_appearance_override.md`. Listen to `NPPDarkModeChangedNotification` and refresh the hex view when fired.

---

## Tab 4: Font

Vertical layout with mixed two-column rows on the bottom.

### Row 1

- Label: `Font Name:`
- Dropdown / popup: list of installed monospaced-style fonts (the Windows reference shows `Courier New`; on macOS the equivalent default is `Menlo` or `SF Mono`).
- Maps to: a new pref (currently the plugin uses `monospacedSystemFontOfSize:`).

### Row 2

- Label: `Font Size:`, dropdown of point sizes (10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32 — the standard set).
- Right of size dropdown: `Bold` checkbox.

### Row 3

- Left: `Capital letters mode` checkbox — when on, render `A-F` digits uppercase (already controlled today by `g_uppercaseHex` if it exists, else add). Verify whether the Windows plugin's "Capital letters" applies to address gutter too.
- Right: `Italic` checkbox.

### Row 4

- Left: `Mirror of Cursor is Rect` checkbox — when on, the ASCII pane's cursor renders as a hollow rectangle (mirror image of the active hex pane's caret). Cosmetic.
- Right: `Underline` checkbox.

Bold / Italic / Underline modify the rendered cell font's traits.

---

## Implementation notes

- All four tabs share the bottom button row (Ok / Cancel, plus our Apply / Reset). Don't duplicate buttons per tab.
- Settings persist to `org.notepad-plus-plus.HexEditor.plist` via the same `hexPref…` helpers used today. Add new keys as needed.
- Layout: each tab's content view is sized to the largest tab's intrinsic content; window grows once on first present. Use NSStackView for in-tab layout where it simplifies the code.
- Tab switching: instant, no save-needed-to-switch behavior. Apply / Ok commits all four tabs at once.
- AX identifiers: prefix every control with `hex-editor.options.<tab>.<control>` so UI tests can reach controls in any tab without depending on tab-switch ordering.

## What goes where (mapping summary)

| Setting | Tab | Today |
| --- | --- | --- |
| Bits per cell (1/2/4/8 byte cells) | Start Layout | Plugins → HexEditor → View submenu |
| Number base (Hex / Binary) | Start Layout | Plugins → HexEditor → View submenu |
| Endianness (BE / LE) | Start Layout | Plugins → HexEditor → View submenu |
| Column Count | Start Layout | Plugins → HexEditor → Columns dialog |
| Address Width | Start Layout | Plugins → HexEditor → Address Width dialog |
| Auto-engage extensions | Startup | (new) |
| Auto-engage control-char threshold | Startup | (new) |
| Color: regular text fg/bg | Colors | (new — uses NSColor defaults today) |
| Color: selection fg/bg | Colors | (new) |
| Color: compare fg/bg | Colors | (new) |
| Color: bookmark fg/bg | Colors | (new) |
| Color: current line bg | Colors | (new) |
| Font name | Font | (new — uses `monospacedSystemFontOfSize:` today) |
| Font size | Font | (zoom delta only today; Cmd+/Cmd-/pinch) |
| Bold / Italic / Underline | Font | (new) |
| Capital letters | Font | (new — currently always lowercase hex) |
| Mirror of Cursor is Rect | Font | (new — cosmetic) |
| Rect-selection modifier | (none) | NPP supports both `Option` and `Shift+Option` natively; no preference needed |

**Resolved** (2026-05-02): the rect-selection modifier setting was removed from the dialog. NPP-Mac now accepts either `Option`-drag or `Shift+Option`-drag for rectangular selection at all times — both NPP conventions, no user toggle. Keyboard rect extend is the canonical `Shift+Option+arrow`. The 4-tab structure here matches the Windows reference exactly.
