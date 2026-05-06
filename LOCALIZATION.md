# Translating the Nextpad++ HexEditor plugin

Thanks for considering a translation. The plugin's UI text — menus,
dialogs, error messages, the About box — is read at runtime from a
small set of plain-text `.strings` files next to the plugin. Adding a
new language is a single file copy + translate + PR; you don't have to
touch any C++ or Swift code, and you don't need a Mac dev environment
to *write* the translation (you only need it if you want to build and
test locally before submitting).

## Quick start

1. **Fork** [this repo on GitHub](https://github.com/dhadner/NPP_HexEdit).
2. **Pick your BCP 47 tag.** Examples: `de` (German), `de-AT` (Austrian
   German), `fr` (French), `pt-BR` (Brazilian Portuguese), `zh-Hans`
   (Simplified Chinese), `ja` (Japanese). If you only have a regional
   variant override (e.g. British English changing a few words from
   the American base), the tag should reflect *just the region* (`en-GB`).
3. **Copy** [`macos/resources/Localizable.en.strings`](macos/resources/Localizable.en.strings)
   to `macos/resources/Localizable.<lang>.strings`.
4. **Translate** the right-hand side of every `"key" = "value";` line.
   Leave the keys (left-hand side) and the comments (`/* … */`) alone.
5. **Register** the new file in [`macos/CMakeLists.txt`](macos/CMakeLists.txt)
   by adding its path to `HEX_LOCALIZATION_FILES`.
6. **Open a pull request** with the two changed files (the new
   `.strings` file and `CMakeLists.txt`). Brief subject line, e.g.
   "Add French (fr) translation" or "British English (en-GB) overrides".

That's the whole flow if you trust the translation without local
testing. If you want to verify it on your own Mac before submitting,
see [Testing your translation](#testing-your-translation) below.

## The file format

The .strings format is plain text. Each line either declares a string
or is a comment.

```text
/* Comment — these explain the meaning of the next key. Keep them
   in English so future translators (and the maintainer) can follow. */
"about.version"       = "Version %1$@";

// Single-line comments are also valid. Less common in this project.
"app.title"           = "HexEditor";
```

**Rules:**

- One key per line. Keys (left-hand side) must NOT change — the
  C++ code looks them up by exact match.
- Values (right-hand side) are double-quoted. Embed a literal `"` as
  `\"`, a literal `\` as `\\`, and a newline as `\n`.
- Every line ends with `;` (semicolon).
- UTF-8. Non-ASCII characters (Umlauts, Cyrillic, CJK, accents) are
  fine as raw bytes — no escaping needed.

### Placeholders

Some strings carry runtime values. **Every placeholder is numbered**
(`%1$@`, `%2$@`, …), even when there's only one — one rule, no
exceptions:

```text
/* %1$@ is a size like "1.5 GB" or "32 bytes". */
"clipboard.large"        = "Large clipboard: %1$@.";

/* Numbered placeholders let you reorder them for a natural-sounding
   sentence in your language. %1$@ is the first arg, %2$@ the second,
   etc. — the numbers refer to the arg the C++ code passes in, not the
   order they appear in the value. You can repeat a number too: French
   reuses %2$@ to drive both noun pluralization and adjective agreement
   from the same English "s" suffix. */
"compare.summary"        = "%1$@ matches, %2$@ differ.";
```

Type letters: `%1$@` for strings/sizes/anything formatted as text,
`%1$d` for integers, `%1$zu` and `%1$lu` for unsigned size-types.
The English source has already chosen the type — keep the same letter
in your translation; only the surrounding text changes.

If you ever see a bare `%@` or `%d` (no number, no `$`) in this
codebase, that's a bug — please flag it in your PR.

## How the plugin chooses your translation

The plugin reads your Mac's preferred-languages list (System Settings
→ General → Language & Region) in order. For each preferred language,
it tries the exact tag first, then the base tag, then moves on to your
next preferred language. Last resort: English.

Example with preferences set to `["de-AT", "en"]`:

| Layer | Tries to read… | If missing, falls back to |
| --- | --- | --- |
| 1 | `Localizable.de-AT.strings` (Austrian-specific overrides) | layer 2 |
| 2 | `Localizable.de.strings` (full German translation) | layer 3 |
| 3 | `Localizable.en.strings` (the canonical English source) | layer 4 |
| 4 | English text built into the plugin itself | (last resort) |

This means **regional variant files only need the keys that DIFFER**
from the base. A Swiss German `de-CH` override only needs to translate
the words that aren't the same as standard `de`. Anywhere a key is
missing, the plugin walks down the layers automatically.

It also means a partial translation is useful — even a French file
with half the keys translated is better than nothing, because the
untranslated keys cascade to English.

## Testing your translation

You can switch the language for *just* Nextpad++ without changing
your whole Mac:

```sh
# Pretend my Mac is set to French for Nextpad++ only.
defaults write org.notepadplusplus.mac AppleLanguages -array fr

# Launch Nextpad++.app from /Applications and engage the HexEditor.
# Verify that menus, dialogs, error messages all show the French strings.

# Put it back when you're done.
defaults delete org.notepadplusplus.mac AppleLanguages
```

(If your translation is a regional override like `en-GB` over `en`,
pass an array of two: `-array en-GB en`. The plugin walks both.)

### Building locally

If you want to build the plugin yourself to test before submitting,
[the macOS DEVELOPER.md](DEVELOPER.md) walks through the toolchain. The
short version once the prerequisites are in place:

```sh
cmake -S macos -B macos/build
cmake --build macos/build --target HexEditor
macos/scripts/install-host-plugin.sh
# Quit Nextpad++ if it's running, relaunch.
```

### Catching layout overflow

UI text in some languages is much longer than the English source —
German is famous for this. The plugin's layout-stress UI tests run
under a synthetic `en-test` locale that doubles every English string,
exposing dialogs that don't expand correctly when text gets longer.
You don't need to run those tests as a translator, but if your
translation pushes a button label or status line off-screen, that's
worth flagging in the PR — it likely means the English source file
needs a layout fix in the corresponding `.swift` / `.mm` file.

## What's already shipped

| File | Status |
| --- | --- |
| [`Localizable.en.strings`](macos/resources/Localizable.en.strings) | Canonical English source — every other file translates from here |
| [`Localizable.en-US.strings`](macos/resources/Localizable.en-US.strings) | American English regional override (slim — essentially identical to `en`, but exists so the cascade test verifies regional overrides load ahead of base) |
| [`Localizable.en-GB.strings`](macos/resources/Localizable.en-GB.strings) | British English regional override (slim) |
| [`Localizable.de.strings`](macos/resources/Localizable.de.strings) | Full German translation |
| [`Localizable.es.strings`](macos/resources/Localizable.es.strings) | Full Spanish translation (neutral, suits both Latin American and Peninsular readers) |
| [`Localizable.es-MX.strings`](macos/resources/Localizable.es-MX.strings) | Mexican Spanish regional override (slim) |
| [`Localizable.es-ES.strings`](macos/resources/Localizable.es-ES.strings) | Peninsular Spanish regional override (slim) |
| [`Localizable.fr.strings`](macos/resources/Localizable.fr.strings) | Full French translation |
| [`Localizable.it.strings`](macos/resources/Localizable.it.strings) | Full Italian translation |
| [`Localizable.pl.strings`](macos/resources/Localizable.pl.strings) | Full Polish translation |
| [`Localizable.ru.strings`](macos/resources/Localizable.ru.strings) | Full Russian translation |
| [`Localizable.uk.strings`](macos/resources/Localizable.uk.strings) | Full Ukrainian translation |
| [`Localizable.zh-Hans.strings`](macos/resources/Localizable.zh-Hans.strings) | Full Simplified Chinese translation |
| [`Localizable.he.strings`](macos/resources/Localizable.he.strings) | Full Hebrew translation (RTL — see "Right-to-left languages" below) |
| [`Localizable.ar.strings`](macos/resources/Localizable.ar.strings) | Full Arabic translation (RTL — see "Right-to-left languages" below) |

If you're adding a new translation that diverges from one of these
existing files (e.g. a Brazilian Portuguese should probably draft from
English, not from any of the Romance translations), copy from
`Localizable.en.strings` and translate from scratch.

## Right-to-left languages

Hebrew and Arabic ship as full translations. macOS automatically flips
menus, NSAlert dialogs, and the host's window chrome under those
locales — that part is free. Two surfaces need explicit handling:

- **The hex view itself** (Offset / hex bytes / ASCII grid) is pinned
  left-to-right regardless of locale. Hex dumps are universally read
  LTR — that's how every hex tool from `xxd` to Hex Fiend renders, and
  how every Hebrew/Arabic-speaking developer reads them. Flipping it
  would mirror the canonical form and break expectations. Pinned at
  [`HexEditor.mm`](macos/src/HexEditor.mm) via
  `userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionLeftToRight`
  on the hex container view, scroll view, and table.
- **The Options dialog tabs** flip under RTL via a coordinate-mirroring
  helper (`hexFlippedX` / `hexFlippedAlignment` in
  [`HexEditor.mm`](macos/src/HexEditor.mm)). Each tab declares a
  single `BOOL isRTL = hexCurrentLayoutIsRTL()` at the top, then wraps
  every `NSMakeRect`'s x-coord with `hexFlippedX` and any explicit
  `NSTextAlignmentRight`/`Left` with `hexFlippedAlignment`. The
  manual-frame layouts stay intact; the helper reflects each element
  about the container's vertical midline so leading-edge content under
  LTR lands on the RTL-leading edge (right side) and trailing-edge
  content (help buttons, hint labels) lands on the RTL-leading
  side.

`hexCurrentLayoutIsRTL()` consults the SAME language preference list
the .strings cascade uses (`HEX_EDITOR_LANG_OVERRIDE` →
`CFPreferencesCopyAppValue` → system) rather than relying on
`NSApp.userInterfaceLayoutDirection` alone. This means the plugin
flips correctly even when the user has set the host system to English
but configured the plugin for Hebrew via
`defaults write org.notepadplusplus.mac AppleLanguages -array he` —
the host doesn't know the user wants RTL, but the plugin does.

Verified by:

- [`testHexTableStaysLTRUnderHebrewLocale`](macos/ui-tests-xcode/Tests/HexEditorUITests.swift)
  asserts under Hebrew that the offset cell's `frame.minX` is less
  than the ASCII cell's — the table stays LTR.
- [`testOptionsDialogFlipsUnderHebrew`](macos/ui-tests-xcode/Tests/HexEditorUITests.swift)
  asserts under Hebrew that the column-count label's `frame.minX` is
  GREATER than the column-count field's — the form mirrored.

If you're translating into a new RTL language (Persian, Urdu, etc.):
no special syntax in the .strings file. The bidi algorithm handles
mixed RTL text + LTR format args (`גרסה %1$@` with %1$@ = "1.1.0"
renders correctly). Just translate the values normally — and add the
language's BCP-47 base tag to the RTL set in
`hexCurrentLayoutIsRTL()` if it isn't already there (Hebrew, Arabic,
Persian, Urdu, Yiddish, Sorani Kurdish, Kashmiri, Pashto, Sindhi, and
Uyghur are pre-registered).

## Patterns for plugin and host developers

If you're working on Nextpad++ itself — or another plugin — the
pieces below were the load-bearing details when getting localization
right in this plugin. Lift any of them.

- **Read user-preferred languages with `CFPreferencesCopyAppValue`,
  not `[NSLocale preferredLanguages]`.** macOS filters `NSLocale`
  against the languages the host app advertises in its bundle's
  `CFBundleLocalizations` / `lproj` directories. If the host ships
  only English, every user-set tag (German, Spanish, Hebrew, ...)
  gets silently dropped before your plugin sees it.
  `CFPreferencesCopyAppValue(@"AppleLanguages", host-bundle-id)`
  returns the user's actual setting, unfiltered. See
  [`hexUserPreferredLanguages()`](macos/src/HexEditor.mm) for the
  reference implementation.
- **Override the language for testing without changing system
  preferences:** read an env var first (e.g. `HEX_EDITOR_LANG_OVERRIDE`),
  fall through to `CFPreferencesCopyAppValue` if unset. UI tests can
  then set `app.launchEnvironment["..."] = "he"` and exercise
  arbitrary locales without touching the user's defaults. See
  [`HexEditorUITests.swift`](macos/ui-tests-xcode/Tests/HexEditorUITests.swift)
  for the launch helper and [`testLocalizationCascadeHebrew`](macos/ui-tests-xcode/Tests/HexEditorUITests.swift)
  through `testLocalizationCascadeArabic` for the cascade-test
  pattern.
- **Always-numbered placeholders**, even single-arg ones. `%1$@`
  instead of `%@`, `%1$d` instead of `%d`. One rule, no carveout. Lets
  translators reorder freely and supports deliberate repetition (a
  single English `s` suffix can drive both noun pluralization and
  adjective agreement in French/Italian by reusing `%2$@`). Costs
  nothing at runtime — Foundation's `+stringWithFormat:` handles both
  forms identically.
- **LTR-pin pattern for data views with intrinsic direction.** Hex
  dumps, log output, line-numbered code, terminal output — these are
  LTR by convention regardless of locale. One line on the container
  view (`view.userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionLeftToRight`)
  keeps them readable while letting the surrounding chrome flip
  naturally. Cheaper than fighting AppKit's RTL machinery for views
  that should never flip.
- **Diagnostic locale tag in the About dialog.** A line that shows
  which `.strings` file the runtime is currently using (`Strings: he`
  / `Strings: zh-Hans` / `Strings: (embedded)` for the embedded
  fallback) makes "did my translation actually load?" a question
  the user can answer in three clicks. The cascade tests assert on
  this string so a misnamed file or broken cascade fails loudly.

## Submitting

Open a PR against the `master` branch. Two files in the diff:

1. The new `.strings` file under `macos/resources/`.
2. `macos/CMakeLists.txt` with the new file added to
   `HEX_LOCALIZATION_FILES`.

A reviewer will eyeball it for the basics (file format, encoding, no
broken keys) and merge. You don't need to add tests; the existing
locale-cascade test verifies the whole layering works for every
shipped language automatically.

If you have questions, open an issue first — happy to help.
