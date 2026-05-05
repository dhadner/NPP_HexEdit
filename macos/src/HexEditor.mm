#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#include "core/HexCore.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <dlfcn.h>
#include <iomanip>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

// Plugin version string — normally injected by CMake's target_compile_definitions
// (`HEX_PLUGIN_VERSION="${PROJECT_VERSION}"`). The fallback here exists only so
// IDE indexers that don't see CMake's flags can parse this file; the shipped
// build always uses the CMake-provided value.
#ifndef HEX_PLUGIN_VERSION
#define HEX_PLUGIN_VERSION "0.0.0"
#endif

// Build tag — git short-hash at configure time, possibly with "-dirty"
// suffix for builds against an uncommitted working tree. Same fallback
// pattern as HEX_PLUGIN_VERSION: IDE indexers see "unknown"; the shipped
// build always carries the CMake-provided real hash. See macos/CMakeLists.txt.
#ifndef HEX_PLUGIN_BUILD
#define HEX_PLUGIN_BUILD "unknown"
#endif

static const char *PLUGIN_NAME = "HexEditor";
static const int NB_FUNC = 7;

// MARK: - Localization
//
// User-facing strings are looked up by key against `Localizable.<lang>.strings`
// files installed alongside the dylib. The lookup walks an ordered chain of
// shipped strings files (built from [NSLocale preferredLanguages]) and finally
// falls through to an embedded English defaults table, so the plugin always
// renders something — never a bare key.
//
// See hexActiveStringsChain() for the chain construction rules and worked
// examples. Tags follow BCP 47 (en, en-GB, de, de-AT, zh-Hans).
//
// Adding a new language: copy `Localizable.en.strings` to
// `Localizable.<lang>.strings`, translate the values, install via CMake.
// The macOS-native .strings format (`"key" = "value";`) is parsed by the
// system via `[NSDictionary dictionaryWithContentsOfURL:]`.

static NSString *hexPluginInstallDir()
{
    // dladdr resolves the path of the dylib that contains the supplied symbol.
    // We pass the address of a static function (`hexPluginInstallDir` itself)
    // and ask dyld which loaded image it lives in. The resulting path looks like
    // `~/.notepad++/plugins/HexEditor/HexEditor.dylib` on a normal install.
    Dl_info info;
    if (dladdr(reinterpret_cast<const void *>(&hexPluginInstallDir), &info) == 0 || !info.dli_fname) {
        return nil;
    }
    NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
    return dylibPath.stringByDeletingLastPathComponent;
}

static NSDictionary<NSString *, NSString *> *hexLoadStringsForLanguage(NSString *language)
{
    NSString *dir = hexPluginInstallDir();
    if (dir == nil || language == nil || language.length == 0) {
        return nil;
    }
    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Localizable.%@.strings", language]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }
    return [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path]];
}

// Build the ORDERED chain of strings dictionaries L() will consult per key.
//
// Rule: iterate the user's preferred languages in order. For each entry, append
// the regional override (if shipped) and then the base language (if shipped) to
// the chain. The user's preferredLanguages list is an explicit, ranked fallback
// declaration set in System Settings → General → Language & Region — we honor
// that ordering, so a user who prefers ["en-GB", "de"] gets en-GB → en → de →
// embedded English defaults. The embedded defaults are added by L() itself.
//
// De-duplication: each shipped file is added at most once. A regional tag and
// its base may both appear in preferredLanguages (e.g. ["en-GB", "en"]); we
// keep the first occurrence and skip later duplicates.
//
// Walked-through example with preferredLanguages = ["en-GB", "de"] and shipped
// files en + de (no en-GB regional override):
//
//   1. raw=en-GB → no Localizable.en-GB.strings, but base "en" matches.
//      chain = [en].
//   2. raw=de → de.strings matches. chain = [en, de].
//   3. L() walks en first, then de, then embedded English defaults.
//
// Walked-through example with ["fr-CA", "de"] and shipped files en + de:
//
//   1. raw=fr-CA → no Localizable.fr-CA.strings, no Localizable.fr.strings.
//      chain unchanged.
//   2. raw=de → de.strings matches. chain = [de].
//   3. L() walks de, then embedded English defaults.
//
// Walked-through example with ["en-GB"] and shipped files en + en-GB:
//
//   1. raw=en-GB → en-GB.strings matches (regional override). en.strings also
//      matches as the base. chain = [en-GB, en].
//   2. L() walks en-GB first, falling through to en for any key the regional
//      file omits.
// Reads the user's raw `AppleLanguages` preference, bypassing the bundle-aware
// filtering that `[NSLocale preferredLanguages]` applies. macOS filters
// `preferredLanguages` against the host bundle's installed `.lproj` directories
// — for Notepad++ macOS, that's `en.lproj` only, which silently drops any
// preference like `de` or `en-GB` and falls back to the system default. Our
// plugin ships its own `Localizable.<lang>.strings` files independent of the
// host's lproj directories, so we want the user's full unfiltered preference
// list. CFPreferencesCopyAppValue with kCFPreferencesCurrentApplication
// returns exactly that for normal launches.
//
// Test override: HEX_EDITOR_LANG_OVERRIDE env var (pipe-separated list of BCP
// 47 tags) takes precedence when set. The XCUITest cascade tier uses this to
// drive the cascade reliably — `defaults write` is silently sandbox-redirected
// when invoked from the XCUI runner, so AppleLanguages overrides written there
// never reach the real user defaults that NPP Mac reads. The env var path is
// not subject to sandbox redirection, sandbox-bound CFPreferences quirks, or
// macOS's bundle-aware preference filtering.
static NSArray<NSString *> *hexUserPreferredLanguages()
{
    NSString *override = NSProcessInfo.processInfo.environment[@"HEX_EDITOR_LANG_OVERRIDE"];
    if (override.length > 0) {
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (NSString *raw in [override componentsSeparatedByString:@"|"]) {
            NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [result addObject:trimmed];
            }
        }
        if (result.count > 0) {
            return result;
        }
    }

    CFTypeRef raw = CFPreferencesCopyAppValue(CFSTR("AppleLanguages"),
                                              kCFPreferencesCurrentApplication);
    NSArray<NSString *> *prefs = nil;
    if (raw != NULL) {
        if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
            // Copy into an autoreleased NSArray so we can release the CF ref
            // immediately. (__bridge_transfer would do this implicitly under
            // ARC; this codebase is MRR.)
            prefs = [(NSArray *)raw copy];
            [prefs autorelease];
        }
        CFRelease(raw);
    }
    // Fall back to NSLocale if CFPreferences didn't give us an array (unusual:
    // happens when neither the app nor global domain has AppleLanguages set,
    // which on a configured macOS install shouldn't occur).
    if (prefs == nil || prefs.count == 0) {
        prefs = [NSLocale preferredLanguages];
    }
    return prefs ?: @[];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *hexActiveStringsChain()
{
    static NSArray<NSDictionary<NSString *, NSString *> *> *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *chain = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        void (^appendIfNew)(NSString *) = ^(NSString *tag) {
            if (tag == nil || tag.length == 0 || [seen containsObject:tag]) {
                return;
            }
            NSDictionary *dict = hexLoadStringsForLanguage(tag);
            if (dict != nil && dict.count > 0) {
                [chain addObject:dict];
                [seen addObject:tag];
            }
        };
        for (NSString *raw in hexUserPreferredLanguages()) {
            appendIfNew(raw);
            NSString *base = [raw componentsSeparatedByString:@"-"].firstObject;
            if (base != nil && ![base isEqualToString:raw]) {
                appendIfNew(base);
            }
        }
        cached = [chain copy];
    });
    return cached;
}

// Embedded English defaults — mirror Localizable.en.strings exactly. The strings
// file is the canonical source for translators; this table is a safety net for
// builds that ship with a missing or corrupted .strings file.
static NSDictionary<NSString *, NSString *> *hexEnglishDefaults()
{
    static NSDictionary<NSString *, NSString *> *defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            // Plugin menu (Plugins > HexEditor > …)
            @"menu.plugin.viewInHex":            @"View in HEX",
            @"menu.plugin.compareHex":           @"Compare HEX",
            @"menu.plugin.clearCompareResult":   @"Clear Compare Result",
            @"menu.plugin.insertColumns":        @"Insert Columns...",
            @"menu.plugin.patternReplace":       @"Pattern Replace...",
            @"menu.plugin.options":              @"Options...",
            @"menu.plugin.help":                 @"Help...",

            // Right-click context menu on the hex view
            @"menu.context.undo":                @"Undo",
            @"menu.context.redo":                @"Redo",
            @"menu.context.cut":                 @"Cut",
            @"menu.context.copy":                @"Copy",
            @"menu.context.paste":               @"Paste",
            @"menu.context.delete":              @"Delete",
            @"menu.context.cutBinary":           @"Cut Binary Content",
            @"menu.context.copyBinary":          @"Copy Binary Content",
            @"menu.context.pasteBinary":         @"Paste Binary Content",
            @"menu.context.find":                @"Find…",
            @"menu.context.findReplace":         @"Find and Replace…",
            @"menu.context.findNext":            @"Find Next",
            @"menu.context.findPrevious":        @"Find Previous",
            @"menu.context.gotoOffset":          @"Go to Offset…",
            @"menu.context.viewIn":              @"View in",
            @"menu.context.addressWidth":        @"Address Width...",
            @"menu.context.columns":             @"Columns...",
            @"menu.context.zoomIn":              @"Zoom In",
            @"menu.context.zoomOut":             @"Zoom Out",
            @"menu.context.zoomReset":           @"Restore Default Zoom",

            // View-in submenu
            @"menu.viewIn.bits8":                @"8-Bit",
            @"menu.viewIn.bits16":               @"16-Bit",
            @"menu.viewIn.bits32":               @"32-Bit",
            @"menu.viewIn.bits64":               @"64-Bit",
            @"menu.viewIn.toBinary":             @"to Binary",
            @"menu.viewIn.toHex":                @"to Hex",
            @"menu.viewIn.toBigEndian":          @"to BigEndian",
            @"menu.viewIn.toLittleEndian":       @"to LittleEndian",

            // Common buttons
            @"button.ok":                        @"OK",
            @"button.cancel":                    @"Cancel",

            // App / dialog identity
            @"app.title":                        @"HexEditor",
            @"app.titleMac":                     @"HexEditor for macOS",
            @"app.titleCompare":                 @"HexEditor Compare",

            // Address Width dialog
            @"addressWidth.title":               @"Address Width",
            @"addressWidth.message":             @"Number of digits in the offset column (%1$d–%2$d).",
            @"addressWidth.invalidRange":        @"Only values between %1$d and %2$d possible.",

            // Columns dialog
            @"columns.title":                    @"Columns",
            @"columns.message":                  @"Number of cells per row (1–%d at the current bit width).",
            @"columns.invalidMaximum":           @"Maximum of %d bytes can be shown in a row.",

            // Go to Offset dialog
            @"goto.title":                       @"Go to Offset",
            @"goto.message":                     @"Enter a byte offset.\n  • Decimal: 1234\n  • Hex: 0x4A2 (or 0X4A2)\n  • Relative: +0x10 jumps forward, -100 jumps back\n\nCurrent: 0x%1$@    End: 0x%2$@",
            @"goto.button":                      @"Go",
            @"goto.placeholder":                 @"e.g. 0x1F or +16",
            @"goto.errorParse":                  @"Could not parse the offset. Use a decimal value, a 0x-prefixed hex value, or a + / - prefix for relative jumps.",

            // Find / Find and Replace dialog
            @"find.titleFind":                   @"Find in Hex",
            @"find.titleReplace":                @"Find and Replace",
            @"find.message":                     @"Plain text searches the buffer as ASCII bytes.\nUse 0x-prefix or space-separated hex (e.g. 0xDEADBEEF or DE AD BE EF) for byte patterns.",
            @"find.button.findNext":             @"Find Next",
            @"find.button.replaceAll":           @"Replace All",
            @"find.placeholder.find":            @"Find: text or 0xDEADBEEF",
            @"find.placeholder.replace":         @"Replace with: text or hex bytes",
            @"find.toggle.matchCase":            @"Match case (ASCII only)",
            @"find.toggle.wrap":                 @"Wrap around end of buffer",
            @"find.errorNotFound":               @"Pattern not found.",
            @"find.errorNoPriorSearch":          @"No prior search. Use Find (Cmd+F) first.",
            @"find.errorParseFind":              @"Could not parse the find pattern.",
            @"find.errorParseReplace":           @"Could not parse the replace pattern.",
            @"find.errorPatternEmpty":           @"Find pattern is empty.",
            @"find.errorNoBuffer":               @"No active hex buffer.",
            @"find.errorNoEditor":               @"No active editor.",
            @"find.errorReplaceFailed":          @"Replace failed.",
            @"find.errorReplaceCurrent":         @"No selection to replace. Use Find Next first.",
            @"find.errorReplaceLength":          @"Current selection does not match the find pattern's length.",
            @"find.errorReplaceFailedShort":    @"Replacement failed.",
            @"find.replacedSingular":            @"Replaced 1 occurrence.",
            @"find.replacedPlural":              @"Replaced %d occurrences.",

            // Compare HEX
            @"compare.openHexFirstCompare":      @"Open the hex view (View in HEX) before using Compare HEX.",
            @"compare.openHexFirstRun":          @"Open the hex view (View in HEX) before running Compare.",
            @"compare.errorNoFile":              @"No comparison file selected.",
            @"compare.errorReadFile":            @"Could not read %1$@: %2$@",
            @"compare.errorReadUnknown":         @"unknown error",
            @"compare.errorFailed":              @"Compare failed.",
            @"compare.openPanelTitle":           @"Compare HEX with…",
            @"compare.openPanelMessage":         @"Pick a file to compare against the current buffer.",
            @"compare.summaryMatch":             @"Files match.",
            @"compare.summaryDifferSingular":    @"1 byte differs.\nUse Clear Compare Result to remove the highlight.",
            @"compare.summaryDifferPlural":      @"%d bytes differ.\nUse Clear Compare Result to remove the highlight.",
            @"compare.noActiveResult":           @"No active comparison to clear.",

            // Insert Columns
            @"insertColumns.openHexFirst":       @"Open the hex view (View in HEX) before using Insert Columns.",
            @"insertColumns.title":              @"Insert Columns",
            @"insertColumns.message":            @"Insert a hex pattern into every row at a chosen column position. Each row grows by (count × %1$d) bytes; the column count grows by `count`.\n\nPattern: hex bytes only (e.g. 0x00 or DE AD).\nCount: 1 to %2$d at the current %3$d-bit grouping.\nPosition: 0 to %4$d (current column count).",
            @"insertColumns.button":             @"Insert",
            @"insertColumns.placeholder.pattern": @"Pattern (hex): 0xFF or DE AD",
            @"insertColumns.placeholder.count":   @"Count (columns to insert)",
            @"insertColumns.placeholder.position": @"Position (column index, 0 = left edge)",
            @"insertColumns.errorEmptyPattern":  @"Pattern is empty.",
            @"insertColumns.errorParsePattern":  @"Pattern must be a sequence of hex bytes (e.g. 0x00, DE AD BE EF).",
            @"insertColumns.errorRangeCount":    @"Column count must be between 1 and %d at the current bit width.",
            @"insertColumns.errorRangePosition": @"Insert position must be between 0 and %d (the current column count).",
            @"insertColumns.errorBufferEmpty":   @"Buffer is empty — nothing to insert into.",
            @"insertColumns.errorRowSize":       @"Invalid current row size.",
            @"insertColumns.errorFailed":        @"Insert failed.",
            @"insertColumns.summarySingularRows": @"Inserted %1$d column%2$@ across 1 row.",
            @"insertColumns.summaryPluralRows":   @"Inserted %1$d column%2$@ across %3$d rows.",

            // Pattern Replace
            @"patternReplace.openHexFirst":      @"Open the hex view (View in HEX) before using Pattern Replace.",
            @"patternReplace.requireSelection": @"Select something in the hex view first — Pattern Replace fills the selection.",
            @"patternReplace.title":             @"Pattern Replace",
            @"patternReplace.message":           @"Fill the current %zu-byte selection with a repeating hex pattern.\n\nPattern: hex bytes only (e.g. 0xFF or DE AD).",
            @"patternReplace.button":            @"Replace",
            @"patternReplace.placeholder":       @"Pattern (hex): 0xFF or DE AD",
            @"patternReplace.errorEmptyPattern": @"Pattern is empty.",
            @"patternReplace.errorParsePattern": @"Pattern must be a sequence of hex bytes (e.g. 0xFF or DE AD BE EF).",
            @"patternReplace.errorFailed":       @"Pattern Replace failed.",
            @"patternReplace.summarySingular":   @"Replaced 1 byte with the pattern.",
            @"patternReplace.summaryPlural":     @"Replaced %d bytes with the pattern.",

            // Status bar (substring-matched by UI tests, so wording is contractual)
            @"status.empty":                     @"Current document is empty.",
            @"status.showing":                   @"Showing %zu bytes.",
            @"status.rectangle":                 @"Rectangle: %1$lu × %2$lu (%3$lu bytes)",

            // Rectangular paste error dialogs (strict shape-match)
            @"paste.rect.errorNeedsRectDestination": @"Destination must be a rectangular selection of %1$lu × %2$lu bytes. Option-drag (or Shift+Option-drag, per Options) to create one.",
            @"paste.rect.errorShapeMismatch":      @"Destination is the wrong size — must be %1$lu bytes wide and %2$lu bytes high.",

            // Pattern Replace — rectangular variant
            @"patternReplace.messageRect":         @"Fill the current %1$lu × %2$lu rectangle with a repeating hex pattern.\nThe pattern restarts at the first byte of each row.\n\nPattern: hex bytes only (e.g. 0xFF or DE AD).",
            @"patternReplace.summaryRect":         @"Filled %1$lu × %2$lu rectangle (%3$lu bytes) with the pattern.",

            // About / help dialog
            // U+2060 Word Joiners between every adjacent pair of
            // characters keep "Notepad++" atomic against both word-wrap
            // (which targets the '+' boundary) and macOS hyphenation
            // (which was breaking it after "Note"). The body refers to
            // the plugin's origin (a Notepad++ plugin on Windows that we
            // ported), not the running host (Nextpad++ on Mac).
            @"about.body":                       @"Native macOS port of the N⁠o⁠t⁠e⁠p⁠a⁠d⁠+⁠+ HEX-Editor plugin. Provides an inline hex table with direct byte editing, selection, bookmarks, find/replace, compare, and view-mode switching.",
            @"about.version":                    @"Version %@",
            // Embedded fallback when no .strings file is loaded — distinct from
            // any shipped tag so the cascade XCTest can detect this state.
            @"about.localeTag":                  @"Strings: (embedded)",

            // Quit-time clipboard prompt (Office/Word pattern). Shown when
            // we hold an outstanding pasteboard promise larger than the
            // silent-materialize threshold and HEX-Editor is about to quit.
            // %1$@ is a human-readable size like "2.0 GB" or "150.0 MB".
            @"clipboard.saveOnQuit.title":         @"Keep clipboard contents?",
            @"clipboard.saveOnQuit.body":          @"You copied %1$@ from the HEX view. Keep it on the clipboard so other apps can paste it after HEX-Editor closes? Discarding releases the memory immediately.",
            @"clipboard.saveOnQuit.keepButton":    @"Keep",
            @"clipboard.saveOnQuit.discardButton": @"Discard",

            // Generic error path used when toggling between Scintilla / hex view
            @"editor.noActiveBuffer":            @"No active editor buffer is available.",
            @"editor.noActiveView":              @"Could not find the active editor view to replace.",

            // Column headers in the hex table
            @"table.header.offset":              @"Offset",
            @"table.header.ascii":               @"ASCII",

            // Help popovers (shared)
            @"help.button.axLabel":              @"Help",

            // Options dialog
            @"options.title":                    @"HexEditor Options",
            @"options.message":                  @"Plugin-wide preferences. Reset restores the defaults shown below; click Save to apply.",
            @"options.button.apply":             @"Apply",
            @"options.button.reset":             @"Reset to Defaults",
            // Tab labels — match the Windows HexEditor plugin's Options dialog
            // (Start Layout, Startup, Colors, Font). Implementation phased in
            // tab-by-tab; non-Start-Layout tabs ship as placeholders for now.
            // See macos/design/options-dialog-reference.md for the truth model.
            @"options.tab.startLayout":          @"Start Layout",
            @"options.tab.startup":              @"Startup",
            @"options.tab.colors":               @"Colors",
            @"options.tab.font":                 @"Font",
            @"options.tab.placeholder":          @"This tab will be populated in a future update.",

            // Start Layout tab — initial state when the hex view opens.
            @"options.startLayout.bits.8":       @"8-Bit",
            @"options.startLayout.bits.16":      @"16-Bit",
            @"options.startLayout.bits.32":      @"32-Bit",
            @"options.startLayout.bits.64":      @"64-Bit",
            @"options.startLayout.base.hex":     @"Hexadecimal",
            @"options.startLayout.base.binary":  @"Binary",
            @"options.startLayout.endian.big":   @"Big-Endian",
            @"options.startLayout.endian.little":@"Little-Endian (Native)",
            @"options.startLayout.columnCount":  @"Column Count:",
            @"options.startLayout.addressWidth": @"Address Width:",
            @"options.startLayout.bits.help":    @"Bytes packed into a single column of the hex view. 8-Bit shows one byte per column in address-ascending order — byte at offset N appears at column N (mod the row width). 16/32/64-Bit pack two/four/eight bytes per column and apply the Endianness setting to choose which byte appears first within each column. Multi-byte columns let you read interpreted integer values directly.",
            @"options.startLayout.base.help":    @"Hexadecimal renders column values in base 16 (00–FF for an 8-bit column). Binary renders the same value as 0/1 digits — useful for inspecting bit-level flags.",
            @"options.startLayout.endian.help":  @"Byte order within a multi-byte column. Big-Endian shows the most significant byte first — matches the wire-order of network traffic dumps and most file-format specs. Little-Endian shows the least significant byte first — matches the in-memory layout on macOS hardware (Apple Silicon and Intel are both little-endian; that's why this option is labelled \"Native\"). At 8-Bit there's no observable difference (single bytes are always shown in address-ascending order), but your choice is preserved — switch back to 16-Bit / 32-Bit / 64-Bit and the same endian setting applies.",
            @"options.startLayout.columnCount.help": @"Number of columns per row in the hex view. Maximum depends on the bits-per-column setting (smaller columns allow more per row; the row never exceeds 128 bytes total).",
            @"options.startLayout.addressWidth.help": @"Number of hex digits shown in the address gutter at the start of each row. 8 digits cover files up to 4 GB; 16 digits is the architectural maximum on a 64-bit system.",

            // Startup tab — auto-engage on NPPN_BUFFERACTIVATED.
            @"options.startup.extensions.label":   @"Extensions:",
            @"options.startup.extensions.hint":    @"e.g.: .dat .bin .exe",
            @"options.startup.extensions.help":    @"Space-separated list of file extensions for which the hex view auto-opens when you switch to that buffer. Each token is matched case-insensitively against the end of the path. Empty string disables this rule.",
            @"options.startup.percent.label":      @"Control char count threshold (%):",
            @"options.startup.percent.help":       @"Sample the first ~1 MB of the active buffer; if at least this percentage of bytes are control characters (below 0x20 excluding tab, CR, LF), auto-open the hex view. Useful for catching binary files whose extension wasn't anticipated. Set to 0 to disable.",

            // Colors tab — per-category Text/Back colour wells.
            @"options.colors.header.text":         @"Text",
            @"options.colors.header.back":         @"Back",
            @"options.colors.row.regularText":     @"Regular Text:",
            @"options.colors.row.selection":       @"Selection:",
            @"options.colors.row.compare":         @"Compare:",
            @"options.colors.row.bookmark":        @"Bookmark:",
            @"options.colors.row.currentLine":     @"Current Line:",
            @"options.colors.help":                @"Pick the foreground (Text) and background (Back) colour for each highlight category. Leaving a well at its default lets the colour follow N⁠e⁠x⁠t⁠p⁠a⁠d⁠+⁠+'s Light/Dark setting automatically — pick a custom colour only if you want a fixed value that doesn't adapt to appearance changes. Reset (in the dialog footer) clears all overrides at once.",

            // Font tab — typography + a couple of cosmetic toggles.
            @"options.font.name":                  @"Font Name:",
            @"options.font.size":                  @"Font Size:",
            @"options.font.bold":                  @"Bold",
            @"options.font.italic":                @"Italic",
            @"options.font.underline":             @"Underline",
            @"options.font.uppercaseHex":          @"Capital letters mode",
            @"options.font.mirrorAsciiCursor":     @"Mirror Cursor as Rect",
            @"options.font.help":                  @"Font Name and Font Size set the typeface used in the hex and ASCII panes (the address column tracks the same font). Bold / Italic / Underline modify the rendered glyphs without changing the underlying byte values. Capital letters mode uppercases the A-F hex digits in both the byte cells and the address column. Mirror Cursor as Rect outlines the corresponding cell in the inactive pane (the hex pane mirrors the ASCII caret as a rectangle and vice versa) so you can see exactly which byte the caret refers to in either view.",
        };
    });
    return defaults;
}

// Look up a localized string by walking the chain of strings layers. The first
// layer that contains a non-empty value for the key wins. Layers are ordered from
// most specific (e.g. en-GB) to most general (en); the embedded English defaults
// are the final fallback so a missing key is never user-visible. Returns the key
// itself only when nothing in the chain or defaults has it — that case shows up
// as a literal "menu.context.foo" string in the UI, intentional dev signal.
// True when `en-test` (a UI-layout stress locale, see `hexExpandedTestString`
// below) is the highest-priority preferred language. Computed once per
// L() lookup — the cost is one NSArray.firstObject + isEqualToString:,
// which is negligible against the dictionary walk we already do.
static BOOL hexLayoutStressLocaleActive()
{
    NSString *first = [hexUserPreferredLanguages() firstObject];
    return [first isEqualToString:@"en-test"];
}

// `en-test` locale transformer: returns the input string repeated three
// times, separated by spaces. Used to prove that dialog layouts survive
// localisation expansion (German, French, Russian, Japanese — all push
// labels well past the English baseline). The transformation is
// deterministic and runs at L()-lookup time, so we don't need to maintain
// a parallel static .strings file that would rot on every English-string
// edit. Numbered placeholders (`%1$@`) round-trip unchanged, so any
// translation-aware formatter still sees them in the right order.
static NSString *hexExpandedTestString(NSString *s)
{
    if (s.length == 0) return s;
    return [NSString stringWithFormat:@"%@ %@ %@", s, s, s];
}

static NSString *L(NSString *key)
{
    NSString *resolved = nil;
    for (NSDictionary<NSString *, NSString *> *layer in hexActiveStringsChain()) {
        NSString *value = layer[key];
        if (value != nil && value.length > 0) {
            resolved = value;
            break;
        }
    }
    if (resolved == nil) {
        resolved = hexEnglishDefaults()[key] ?: key;
    }
    if (hexLayoutStressLocaleActive()) {
        return hexExpandedTestString(resolved);
    }
    return resolved;
}

// Accessibility identifiers — must match the strings hard-coded in
// macos/ui-tests-xcode/Tests/HexEditorUITests.swift.
static NSString *const kHexEditorRootAccessibilityID = @"hex-editor.root";
static NSString *const kHexEditorTableAccessibilityID = @"hex-editor.table";
static NSString *const kHexEditorStatusAccessibilityID = @"hex-editor.status";
// Hidden diagnostic surface that lets the XCTest UI suite read the hex view's
// caret offset and selection range. NSTableView does not expose these via AX,
// and writing an accessibilityValue onto the table itself would clash with the
// default row/cell semantics. The diagnostic element below is purely additive.
static NSString *const kHexEditorCursorAccessibilityID = @"hex-editor.cursor.diagnostic";
static const CGFloat HEX_TABLE_HEIGHT = 640.0;
static const CGFloat HEX_STATUS_HEIGHT = 24.0;
static const CGFloat HEX_FALLBACK_FONT_SIZE = 10.0;
// Horizontal padding added to each byte cell's text width, expressed in
// monospaced glyph widths so the visible gap between adjacent cells stays
// proportional to the current font (otherwise the gap shrinks visually at
// high zoom). Half is split to the left of the glyph, half to the right
// (centre alignment). At a typical 10-pt monospaced font glyph width is
// ~6 pt → ~2.4 pt total gap, ≈ 20% wider than the original 2-pt fixed gap.
static const CGFloat HEX_CELL_HORIZONTAL_PADDING_GLYPHS = 0.4;
// Inter-pane gaps are derived from the current font's monospaced glyph width so
// they scale with pinch-zoom — fixed-pt values would look generous at small font
// sizes and disappear at large ones. See offsetTrailingPadding / asciiSeparatorWidth.
static const CGFloat HEX_OFFSET_TRAILING_GLYPHS = 1.0;
static const CGFloat HEX_ASCII_SEPARATOR_GLYPHS = 0.5;
static const CGFloat HEX_MIN_FONT_SIZE = 6.0;
static const CGFloat HEX_MAX_FONT_SIZE = 32.0;
static const CGFloat HEX_CARET_WIDTH = 2.0;

static NSString *const HEX_PREFS_SUITE = @"org.notepad-plus-plus.HexEditor";
static NSString *const HEX_PREF_BYTES_PER_CELL = @"bytesPerCell";
static NSString *const HEX_PREF_NOTATION_BINARY = @"notationBinary";
static NSString *const HEX_PREF_LITTLE_ENDIAN = @"littleEndian";
static NSString *const HEX_PREF_ADDRESS_WIDTH = @"addressWidth";
static NSString *const HEX_PREF_COLUMNS = @"columns";
static NSString *const HEX_PREF_FIND_MATCH_CASE = @"findMatchCase";
static NSString *const HEX_PREF_FIND_WRAP = @"findWrap";
// Startup auto-engage prefs (Options → Startup tab). Match Windows:
// - extensions: space-separated list (e.g. ".dat .bin .exe"); buffer file
//   path matching any token auto-opens the hex view on activation.
// - controlCharPercent: 0–99. Sample first N bytes of buffer; if at least
//   N * percent / 100 bytes are control chars (< 0x20 except tab/CR/LF),
//   auto-open the hex view. 0 disables this heuristic.
static NSString *const HEX_PREF_AUTO_EXTENSIONS = @"autoEngageExtensions";
static NSString *const HEX_PREF_AUTO_CONTROL_PERCENT = @"autoEngageControlCharPercent";
// Font tab keys. Defaults are deliberately conservative: Menlo at 12pt with
// no traits, no uppercase, mirror cursor off (the user opts into the
// hollow-rectangle indicator if they want it; default is the unadorned
// caret). Empty fontName / 0 size = "use system fallback"
// (monospacedSystemFontOfSize: at the Scintilla-derived size).
static NSString *const HEX_PREF_FONT_NAME           = @"font.name";
static NSString *const HEX_PREF_FONT_SIZE           = @"font.size";
static NSString *const HEX_PREF_FONT_BOLD           = @"font.bold";
static NSString *const HEX_PREF_FONT_ITALIC         = @"font.italic";
static NSString *const HEX_PREF_FONT_UNDERLINE      = @"font.underline";
static NSString *const HEX_PREF_FONT_UPPERCASE_HEX  = @"font.uppercaseHex";
static NSString *const HEX_PREF_MIRROR_ASCII_CURSOR = @"font.mirrorAsciiCursor";

static NSString *const HEX_DEFAULT_FONT_NAME = @"Menlo";
static const int HEX_DEFAULT_FONT_SIZE_PT = 12;
static const int HEX_FONT_SIZE_MIN_PT = 6;
static const int HEX_FONT_SIZE_MAX_PT = 72;
// Colors tab — Text (foreground) and Back (background) per category. Stored
// as archived NSData so any colour space + alpha round-trips. Missing key /
// nil decoded value = "use the default" (the existing dynamic system colour),
// which is what we want for both fresh installs and unchanged categories.
// Per-mode color override pref keys. Each setting has Light + Dark slots;
// presence of a key means "this mode has a user override", absence means
// "use the factory default for this mode" (which the resolve helpers fetch
// from hexFactory*Light() / hexFactory*Dark() at draw time, so changing
// hard-coded factory values in a new release immediately takes effect for
// any user who hadn't actively customised that slot).
static NSString *const HEX_PREF_COLOR_REG_TEXT_FG_LIGHT     = @"color.regularText.fg.light";
static NSString *const HEX_PREF_COLOR_REG_TEXT_FG_DARK      = @"color.regularText.fg.dark";
static NSString *const HEX_PREF_COLOR_REG_TEXT_BG_LIGHT     = @"color.regularText.bg.light";
static NSString *const HEX_PREF_COLOR_REG_TEXT_BG_DARK      = @"color.regularText.bg.dark";
static NSString *const HEX_PREF_COLOR_SELECTION_FG_LIGHT    = @"color.selection.fg.light";
static NSString *const HEX_PREF_COLOR_SELECTION_FG_DARK     = @"color.selection.fg.dark";
static NSString *const HEX_PREF_COLOR_SELECTION_BG_LIGHT    = @"color.selection.bg.light";
static NSString *const HEX_PREF_COLOR_SELECTION_BG_DARK     = @"color.selection.bg.dark";
static NSString *const HEX_PREF_COLOR_COMPARE_FG_LIGHT      = @"color.compare.fg.light";
static NSString *const HEX_PREF_COLOR_COMPARE_FG_DARK       = @"color.compare.fg.dark";
static NSString *const HEX_PREF_COLOR_COMPARE_BG_LIGHT      = @"color.compare.bg.light";
static NSString *const HEX_PREF_COLOR_COMPARE_BG_DARK       = @"color.compare.bg.dark";
static NSString *const HEX_PREF_COLOR_BOOKMARK_FG_LIGHT     = @"color.bookmark.fg.light";
static NSString *const HEX_PREF_COLOR_BOOKMARK_FG_DARK      = @"color.bookmark.fg.dark";
static NSString *const HEX_PREF_COLOR_BOOKMARK_BG_LIGHT     = @"color.bookmark.bg.light";
static NSString *const HEX_PREF_COLOR_BOOKMARK_BG_DARK      = @"color.bookmark.bg.dark";
static NSString *const HEX_PREF_COLOR_CURRENT_LINE_BG_LIGHT = @"color.currentLine.bg.light";
static NSString *const HEX_PREF_COLOR_CURRENT_LINE_BG_DARK  = @"color.currentLine.bg.dark";

// Legacy single-set color keys (pre-2026-05-03). Read once on load as
// fallback for the new per-mode keys, then removed on next save. After all
// active installs have migrated they could be deleted entirely; keep here
// for now so users upgrading from older builds don't lose their picks.
static NSString *const HEX_PREF_COLOR_REG_TEXT_FG_LEGACY     = @"color.regularText.fg";
static NSString *const HEX_PREF_COLOR_REG_TEXT_BG_LEGACY     = @"color.regularText.bg";
static NSString *const HEX_PREF_COLOR_SELECTION_FG_LEGACY    = @"color.selection.fg";
static NSString *const HEX_PREF_COLOR_SELECTION_BG_LEGACY    = @"color.selection.bg";
static NSString *const HEX_PREF_COLOR_COMPARE_FG_LEGACY      = @"color.compare.fg";
static NSString *const HEX_PREF_COLOR_COMPARE_BG_LEGACY      = @"color.compare.bg";
static NSString *const HEX_PREF_COLOR_BOOKMARK_FG_LEGACY     = @"color.bookmark.fg";
static NSString *const HEX_PREF_COLOR_BOOKMARK_BG_LEGACY     = @"color.bookmark.bg";
static NSString *const HEX_PREF_COLOR_CURRENT_LINE_BG_LEGACY = @"color.currentLine.bg";

// Sample size for the control-char density heuristic. Match the Windows
// AUTOSTART_MAX (~1 MB). We never read more than this even for huge files
// because the density signal saturates well below that — control bytes in
// a binary file cluster densely enough that a 1 MB sample reliably exceeds
// any reasonable percent threshold.
static const NSUInteger HEX_AUTOSTART_SAMPLE_BYTES = 1024 * 1024;

static NSString *g_lastFindText = @"";
static NSString *g_lastReplaceText = @"";
static bool g_findMatchCase = true;
static bool g_findWrap = true;

static const int HEX_DEFAULT_ADDRESS_WIDTH = 8;
static const int HEX_DEFAULT_COLUMNS = 16;
static const int HEX_MIN_ADDRESS_WIDTH = 4;
static const int HEX_MAX_ADDRESS_WIDTH = 16;
static const int HEX_MAX_BYTES_PER_ROW = 128;

static int g_bytesPerCell = 1;
static hexedit::CellNotation g_notation = hexedit::CellNotation::Hex;
static bool g_littleEndian = false;
static int g_addressWidth = HEX_DEFAULT_ADDRESS_WIDTH;
static int g_columns = HEX_DEFAULT_COLUMNS;
// Auto-engage state. Empty extensions / 0 percent = feature off (default).
static NSString *g_autoExtensions = @"";
static int g_autoControlPercent = 0;
// Font-tab state. fontName / fontSize default to Menlo / 12pt; an empty
// fontName means "fall back to monospacedSystemFontOfSize:" (the historical
// behaviour, useful if Menlo is somehow unavailable). The Cmd+/Cmd− zoom
// delta still applies on top of fontSize at render time.
static NSString *g_fontName = nil;        // copy of HEX_DEFAULT_FONT_NAME after load
static int g_fontSize = HEX_DEFAULT_FONT_SIZE_PT;
static bool g_fontBold = false;
static bool g_fontItalic = false;
static bool g_fontUnderline = false;
static bool g_uppercaseHex = false;
static bool g_mirrorAsciiCursor = false;
// Diagnostic stash for the caret's last-rendered geometry. Reset at the
// start of every HexTableView.drawRect: paint and set to true only when
// drawRect: actually paints the caret stripe. Read by
// HexCursorDiagnosticView so UI tests can assert that a given cursor /
// rect state landed on the expected pixel column. The bool flag avoids
// the NaN-sentinel pattern (NaN propagates silently through any further
// math, easy to miss); when g_caretLastRenderedValid == false the X /
// Row / CellMinX values are stale and consumers must not use them.
static bool g_caretLastRenderedValid = false;
static CGFloat g_caretLastRenderedX = 0.0;
static NSInteger g_caretLastRenderedRow = -1;
static CGFloat g_caretLastRenderedCellMinX = 0.0;
// Mirror-cursor diagnostic: width of the last-drawn mirror rectangle in
// pt. 0 = mirror was not drawn this paint (either disabled, no caret,
// or out of bounds). Read by UI tests to verify the Mirror Cursor as
// Rect toggle reaches the rendering path. Width is naturally always
// positive when drawn, so 0 is a clear unambiguous "not drawn" marker
// (no NaN-sentinel needed — width is bounded below by glyphWidth ≥ 1).
static CGFloat g_mirrorLastRenderedWidth = 0.0;
// Per-category, per-mode colour overrides. nil = "use the factory default
// for this mode" (which the resolve helpers fetch from hexFactory*Light()
// / hexFactory*Dark() at draw time). This lets us change hard-coded factory
// hexes between releases and have any user who's still on defaults pick up
// the new values automatically — only users who actively customised a slot
// retain their pinned choice. Light and Dark are independent: customising
// Selection bg in Light mode does NOT affect what Dark mode shows. The
// Colors tab writes through to the active mode's slot when the user picks
// a colour, leaving the other mode untouched.
static NSColor *g_colorRegularTextFgLight    = nil;
static NSColor *g_colorRegularTextFgDark     = nil;
static NSColor *g_colorRegularTextBgLight    = nil;
static NSColor *g_colorRegularTextBgDark     = nil;
static NSColor *g_colorSelectionFgLight      = nil;
static NSColor *g_colorSelectionFgDark       = nil;
static NSColor *g_colorSelectionBgLight      = nil;
static NSColor *g_colorSelectionBgDark       = nil;
static NSColor *g_colorCompareFgLight        = nil;
static NSColor *g_colorCompareFgDark         = nil;
static NSColor *g_colorCompareBgLight        = nil;
static NSColor *g_colorCompareBgDark         = nil;
static NSColor *g_colorBookmarkFgLight       = nil;
static NSColor *g_colorBookmarkFgDark        = nil;
static NSColor *g_colorBookmarkBgLight       = nil;
static NSColor *g_colorBookmarkBgDark        = nil;
static NSColor *g_colorCurrentLineBgLight    = nil;
static NSColor *g_colorCurrentLineBgDark     = nil;

static NSUserDefaults *hexPrefs()
{
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:HEX_PREFS_SUITE];
    });
    return prefs;
}

static int hexPrefInt(NSString *key, int fallback)
{
    NSUserDefaults *prefs = hexPrefs();
    if (![prefs objectForKey:key]) {
        return fallback;
    }
    return static_cast<int>([prefs integerForKey:key]);
}

static void hexPrefSetInt(NSString *key, int value)
{
    [hexPrefs() setInteger:value forKey:key];
}

static bool hexPrefBool(NSString *key, bool fallback)
{
    NSUserDefaults *prefs = hexPrefs();
    if (![prefs objectForKey:key]) {
        return fallback;
    }
    return [prefs boolForKey:key] ? true : false;
}

static void hexPrefSetBool(NSString *key, bool value)
{
    [hexPrefs() setBool:value forKey:key];
}

static NSString *hexPrefString(NSString *key, NSString *fallback)
{
    NSString *value = [hexPrefs() stringForKey:key];
    return value ?: fallback;
}

static void hexPrefSetString(NSString *key, NSString *value)
{
    [hexPrefs() setObject:value forKey:key];
}

// NSColor ↔ NSData via NSKeyedArchiver. Round-trips colour space and alpha
// faithfully so a re-launched plugin renders exactly what the user picked.
// nil colour → remove the key (so the fallback path kicks in); nil/missing
// data on read → nil colour (caller falls back).
static NSColor *hexPrefColor(NSString *key)
{
    NSData *data = [hexPrefs() dataForKey:key];
    if (data.length == 0) return nil;
    NSError *err = nil;
    NSColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class]
                                                       fromData:data
                                                          error:&err];
    return color;
}

// MRC-safe assignment helper for the g_color* slots. Without ARC a plain
// `g_color = newColor` doesn't retain the new value or release the old —
// any colour assigned this way (e.g. an autoreleased NSColor pulled from
// an NSColorWell or NSKeyedUnarchiver) gets freed when its owner goes
// away, leaving the static pointer dangling. drawRect: then calls setFill
// on the freed object and crashes (EXC_BAD_ACCESS in objc_msgSend). All
// g_color* mutation must go through this helper.
static void setHexColor(NSColor **slot, NSColor *value)
{
    if (*slot == value) return;
    [value retain];
    [*slot release];
    *slot = value;
}

static void hexPrefSetColor(NSString *key, NSColor *color)
{
    if (color == nil) {
        [hexPrefs() removeObjectForKey:key];
        return;
    }
    NSError *err = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color
                                          requiringSecureCoding:NO
                                                          error:&err];
    if (data) {
        [hexPrefs() setObject:data forKey:key];
    }
}

static int currentBytesPerRow()
{
    return std::max(g_columns, 1) * std::max(g_bytesPerCell, 1);
}

static hexedit::ViewMode currentViewMode()
{
    hexedit::ViewMode mode;
    mode.bytesPerCell = g_bytesPerCell;
    mode.notation = g_notation;
    mode.littleEndian = g_littleEndian;
    mode.uppercase = g_uppercaseHex;
    return mode;
}

static int currentCellsPerRow()
{
    return std::max(g_columns, 1);
}

static int currentDigitsPerCell()
{
    return hexedit::digitsPerCell(currentViewMode());
}

static int columnsLimitForBytesPerCell(int bytesPerCell)
{
    if (!hexedit::isValidBytesPerCell(bytesPerCell)) {
        return HEX_DEFAULT_COLUMNS;
    }
    return HEX_MAX_BYTES_PER_ROW / bytesPerCell;
}

static int defaultColumnsForBytesPerCell(int bytesPerCell)
{
    return std::max(1, HEX_DEFAULT_COLUMNS / std::max(bytesPerCell, 1));
}

static void loadHexPrefs()
{
    int bpc = hexPrefInt(HEX_PREF_BYTES_PER_CELL, 1);
    if (!hexedit::isValidBytesPerCell(bpc)) {
        bpc = 1;
    }
    g_bytesPerCell = bpc;
    g_notation = hexPrefBool(HEX_PREF_NOTATION_BINARY, false)
        ? hexedit::CellNotation::Binary
        : hexedit::CellNotation::Hex;
    // Default to Little-Endian: Apple Silicon, Intel, ARM (Linux),
    // Windows-on-x64 — basically every system you'd open a hex view on
    // is little-endian. Big-Endian is reserved for network-protocol
    // dumps (TCP/IP wire order) and a handful of legacy file formats;
    // most users would never need it. New installs (no pref key set)
    // start at Little; existing installs keep whatever they previously
    // saved.
    g_littleEndian = hexPrefBool(HEX_PREF_LITTLE_ENDIAN, true);
    g_addressWidth = std::clamp(
        hexPrefInt(HEX_PREF_ADDRESS_WIDTH, HEX_DEFAULT_ADDRESS_WIDTH),
        HEX_MIN_ADDRESS_WIDTH,
        HEX_MAX_ADDRESS_WIDTH);
    const int columnsLimit = columnsLimitForBytesPerCell(g_bytesPerCell);
    int columns = hexPrefInt(HEX_PREF_COLUMNS, defaultColumnsForBytesPerCell(g_bytesPerCell));
    g_columns = std::clamp(columns, 1, columnsLimit);
    g_findMatchCase = hexPrefBool(HEX_PREF_FIND_MATCH_CASE, true);
    g_findWrap = hexPrefBool(HEX_PREF_FIND_WRAP, true);
    g_autoExtensions = hexPrefString(HEX_PREF_AUTO_EXTENSIONS, @"") ?: @"";
    g_autoControlPercent = std::clamp(hexPrefInt(HEX_PREF_AUTO_CONTROL_PERCENT, 0), 0, 99);
    g_fontName = [hexPrefString(HEX_PREF_FONT_NAME, HEX_DEFAULT_FONT_NAME) ?: HEX_DEFAULT_FONT_NAME copy];
    g_fontSize = std::clamp(hexPrefInt(HEX_PREF_FONT_SIZE, HEX_DEFAULT_FONT_SIZE_PT),
                             HEX_FONT_SIZE_MIN_PT, HEX_FONT_SIZE_MAX_PT);
    g_fontBold = hexPrefBool(HEX_PREF_FONT_BOLD, false);
    g_fontItalic = hexPrefBool(HEX_PREF_FONT_ITALIC, false);
    g_fontUnderline = hexPrefBool(HEX_PREF_FONT_UNDERLINE, false);
    g_uppercaseHex = hexPrefBool(HEX_PREF_FONT_UPPERCASE_HEX, false);
    g_mirrorAsciiCursor = hexPrefBool(HEX_PREF_MIRROR_ASCII_CURSOR, false);
    // Color overrides: read new per-mode keys; if absent and a legacy
    // single-set key is present, copy the legacy value into BOTH modes
    // (preserves the user's prior pick across the migration). The legacy
    // keys are removed by the next saveHexPrefs() call below.
    NSColor *legacyRegFg     = hexPrefColor(HEX_PREF_COLOR_REG_TEXT_FG_LEGACY);
    NSColor *legacyRegBg     = hexPrefColor(HEX_PREF_COLOR_REG_TEXT_BG_LEGACY);
    NSColor *legacySelFg     = hexPrefColor(HEX_PREF_COLOR_SELECTION_FG_LEGACY);
    NSColor *legacySelBg     = hexPrefColor(HEX_PREF_COLOR_SELECTION_BG_LEGACY);
    NSColor *legacyCmpFg     = hexPrefColor(HEX_PREF_COLOR_COMPARE_FG_LEGACY);
    NSColor *legacyCmpBg     = hexPrefColor(HEX_PREF_COLOR_COMPARE_BG_LEGACY);
    NSColor *legacyBmkFg     = hexPrefColor(HEX_PREF_COLOR_BOOKMARK_FG_LEGACY);
    NSColor *legacyBmkBg     = hexPrefColor(HEX_PREF_COLOR_BOOKMARK_BG_LEGACY);
    NSColor *legacyCurBg     = hexPrefColor(HEX_PREF_COLOR_CURRENT_LINE_BG_LEGACY);

    setHexColor(&g_colorRegularTextFgLight, hexPrefColor(HEX_PREF_COLOR_REG_TEXT_FG_LIGHT)     ?: legacyRegFg);
    setHexColor(&g_colorRegularTextFgDark,  hexPrefColor(HEX_PREF_COLOR_REG_TEXT_FG_DARK)      ?: legacyRegFg);
    setHexColor(&g_colorRegularTextBgLight, hexPrefColor(HEX_PREF_COLOR_REG_TEXT_BG_LIGHT)     ?: legacyRegBg);
    setHexColor(&g_colorRegularTextBgDark,  hexPrefColor(HEX_PREF_COLOR_REG_TEXT_BG_DARK)      ?: legacyRegBg);
    setHexColor(&g_colorSelectionFgLight,   hexPrefColor(HEX_PREF_COLOR_SELECTION_FG_LIGHT)    ?: legacySelFg);
    setHexColor(&g_colorSelectionFgDark,    hexPrefColor(HEX_PREF_COLOR_SELECTION_FG_DARK)     ?: legacySelFg);
    setHexColor(&g_colorSelectionBgLight,   hexPrefColor(HEX_PREF_COLOR_SELECTION_BG_LIGHT)    ?: legacySelBg);
    setHexColor(&g_colorSelectionBgDark,    hexPrefColor(HEX_PREF_COLOR_SELECTION_BG_DARK)     ?: legacySelBg);
    setHexColor(&g_colorCompareFgLight,     hexPrefColor(HEX_PREF_COLOR_COMPARE_FG_LIGHT)      ?: legacyCmpFg);
    setHexColor(&g_colorCompareFgDark,      hexPrefColor(HEX_PREF_COLOR_COMPARE_FG_DARK)       ?: legacyCmpFg);
    setHexColor(&g_colorCompareBgLight,     hexPrefColor(HEX_PREF_COLOR_COMPARE_BG_LIGHT)      ?: legacyCmpBg);
    setHexColor(&g_colorCompareBgDark,      hexPrefColor(HEX_PREF_COLOR_COMPARE_BG_DARK)       ?: legacyCmpBg);
    setHexColor(&g_colorBookmarkFgLight,    hexPrefColor(HEX_PREF_COLOR_BOOKMARK_FG_LIGHT)     ?: legacyBmkFg);
    setHexColor(&g_colorBookmarkFgDark,     hexPrefColor(HEX_PREF_COLOR_BOOKMARK_FG_DARK)      ?: legacyBmkFg);
    setHexColor(&g_colorBookmarkBgLight,    hexPrefColor(HEX_PREF_COLOR_BOOKMARK_BG_LIGHT)     ?: legacyBmkBg);
    setHexColor(&g_colorBookmarkBgDark,     hexPrefColor(HEX_PREF_COLOR_BOOKMARK_BG_DARK)      ?: legacyBmkBg);
    setHexColor(&g_colorCurrentLineBgLight, hexPrefColor(HEX_PREF_COLOR_CURRENT_LINE_BG_LIGHT) ?: legacyCurBg);
    setHexColor(&g_colorCurrentLineBgDark,  hexPrefColor(HEX_PREF_COLOR_CURRENT_LINE_BG_DARK)  ?: legacyCurBg);
}

static void saveHexPrefs()
{
    hexPrefSetInt(HEX_PREF_BYTES_PER_CELL, g_bytesPerCell);
    hexPrefSetBool(HEX_PREF_NOTATION_BINARY, g_notation == hexedit::CellNotation::Binary);
    hexPrefSetBool(HEX_PREF_LITTLE_ENDIAN, g_littleEndian);
    hexPrefSetInt(HEX_PREF_ADDRESS_WIDTH, g_addressWidth);
    hexPrefSetInt(HEX_PREF_COLUMNS, g_columns);
    hexPrefSetString(HEX_PREF_AUTO_EXTENSIONS, g_autoExtensions ?: @"");
    hexPrefSetInt(HEX_PREF_AUTO_CONTROL_PERCENT, g_autoControlPercent);
    hexPrefSetString(HEX_PREF_FONT_NAME, g_fontName ?: HEX_DEFAULT_FONT_NAME);
    hexPrefSetInt(HEX_PREF_FONT_SIZE, g_fontSize);
    hexPrefSetBool(HEX_PREF_FONT_BOLD, g_fontBold);
    hexPrefSetBool(HEX_PREF_FONT_ITALIC, g_fontItalic);
    hexPrefSetBool(HEX_PREF_FONT_UNDERLINE, g_fontUnderline);
    hexPrefSetBool(HEX_PREF_FONT_UPPERCASE_HEX, g_uppercaseHex);
    hexPrefSetBool(HEX_PREF_MIRROR_ASCII_CURSOR, g_mirrorAsciiCursor);
    hexPrefSetColor(HEX_PREF_COLOR_REG_TEXT_FG_LIGHT,     g_colorRegularTextFgLight);
    hexPrefSetColor(HEX_PREF_COLOR_REG_TEXT_FG_DARK,      g_colorRegularTextFgDark);
    hexPrefSetColor(HEX_PREF_COLOR_REG_TEXT_BG_LIGHT,     g_colorRegularTextBgLight);
    hexPrefSetColor(HEX_PREF_COLOR_REG_TEXT_BG_DARK,      g_colorRegularTextBgDark);
    hexPrefSetColor(HEX_PREF_COLOR_SELECTION_FG_LIGHT,    g_colorSelectionFgLight);
    hexPrefSetColor(HEX_PREF_COLOR_SELECTION_FG_DARK,     g_colorSelectionFgDark);
    hexPrefSetColor(HEX_PREF_COLOR_SELECTION_BG_LIGHT,    g_colorSelectionBgLight);
    hexPrefSetColor(HEX_PREF_COLOR_SELECTION_BG_DARK,     g_colorSelectionBgDark);
    hexPrefSetColor(HEX_PREF_COLOR_COMPARE_FG_LIGHT,      g_colorCompareFgLight);
    hexPrefSetColor(HEX_PREF_COLOR_COMPARE_FG_DARK,       g_colorCompareFgDark);
    hexPrefSetColor(HEX_PREF_COLOR_COMPARE_BG_LIGHT,      g_colorCompareBgLight);
    hexPrefSetColor(HEX_PREF_COLOR_COMPARE_BG_DARK,       g_colorCompareBgDark);
    hexPrefSetColor(HEX_PREF_COLOR_BOOKMARK_FG_LIGHT,     g_colorBookmarkFgLight);
    hexPrefSetColor(HEX_PREF_COLOR_BOOKMARK_FG_DARK,      g_colorBookmarkFgDark);
    hexPrefSetColor(HEX_PREF_COLOR_BOOKMARK_BG_LIGHT,     g_colorBookmarkBgLight);
    hexPrefSetColor(HEX_PREF_COLOR_BOOKMARK_BG_DARK,      g_colorBookmarkBgDark);
    hexPrefSetColor(HEX_PREF_COLOR_CURRENT_LINE_BG_LIGHT, g_colorCurrentLineBgLight);
    hexPrefSetColor(HEX_PREF_COLOR_CURRENT_LINE_BG_DARK,  g_colorCurrentLineBgDark);

    // Migration: clear legacy single-set keys once they've been folded
    // into the new per-mode globals (loadHexPrefs reads them as fallback).
    // After all installs save once, the legacy keys are gone. Keeping the
    // remove-calls indefinitely is harmless — removeObjectForKey is a
    // no-op for absent keys.
    NSUserDefaults *prefs = hexPrefs();
    [prefs removeObjectForKey:HEX_PREF_COLOR_REG_TEXT_FG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_REG_TEXT_BG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_SELECTION_FG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_SELECTION_BG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_COMPARE_FG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_COMPARE_BG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_BOOKMARK_FG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_BOOKMARK_BG_LEGACY];
    [prefs removeObjectForKey:HEX_PREF_COLOR_CURRENT_LINE_BG_LEGACY];
}

static FuncItem funcItem[NB_FUNC];
static ShortcutKey hexShortcut = { false, true, true, true, 'H' };
static NppData nppData = {};
static NSView *hexRootView = nil;
static NSTableView *hexTableView = nil;
static NSTextField *hexStatusLabel = nil;
static NSView *hexEditorView = nil;
static NSView *hiddenScintillaView = nil;

// Per-buffer "user explicitly engaged hex view here" intent. Survives
// tab-switch buffer activations so hex view comes back when the user
// returns to the tab — independent of the Startup auto-engage rules
// (which only fire for files matching the configured extension list or
// content-density threshold). User-discovered bug 2026-05-05: switching
// away from a hex-view tab and back reverted to text view for any file
// that didn't separately match the auto-engage rules.
//
// Keyed by NppHandle (the host's bufferId, which is the address of the
// editor NSView under NPP-Mac). Wrapped in NSValue so an NSMutableSet
// can hold it. Entries are added when the user calls showHexPreview()
// (via the menu), removed on user-initiated toggle-off, and removed
// when the host notifies that a buffer is closing.
static NSMutableSet<NSValue *> *g_buffersWithHexIntent = nil;

static NSMutableSet<NSValue *> *hexIntentSet()
{
    if (g_buffersWithHexIntent == nil) {
        g_buffersWithHexIntent = [[NSMutableSet alloc] init];
    }
    return g_buffersWithHexIntent;
}

static NSValue *bufferIdValue(uintptr_t bufferId)
{
    return [NSValue valueWithPointer:reinterpret_cast<const void *>(bufferId)];
}

static void recordHexIntent(uintptr_t bufferId)
{
    if (bufferId == 0) return;
    [hexIntentSet() addObject:bufferIdValue(bufferId)];
}

static void clearHexIntent(uintptr_t bufferId)
{
    if (bufferId == 0) return;
    [hexIntentSet() removeObject:bufferIdValue(bufferId)];
}

static bool hasHexIntent(uintptr_t bufferId)
{
    if (bufferId == 0) return false;
    return [hexIntentSet() containsObject:bufferIdValue(bufferId)];
}
// Long-lived byte-source backing the hex view. Replaces the previous
// in-RAM previewBytes vector — the lazy-Scintilla migration of 2026-05-05
// (Step 2c). Reads go on demand against the active Scintilla buffer via
// WindowedScintillaByteSource's page cache, so plugin RAM stays bounded
// by the cache size (~4 MB) regardless of document length.
//
// Lifecycle is owned by bindHexBufferToActiveScintilla() and
// invalidateHexBuffer() below. Direct g_hexBuffer access by consumers is
// discouraged — go through the hexBufferLength / hexBufferEmpty /
// hexByteAt / hexBytesIn / hexBufferSource accessors so we keep one
// path through the null-check.
//
// Destruction order: g_hexBuffer holds a reference into *g_hexReader,
// so g_hexBuffer must reset *first*. unique_ptr destructors run in
// reverse declaration order, so g_hexBuffer is declared *after*
// g_hexReader to make this happen automatically.
static std::unique_ptr<hexedit::SciReader> g_hexReader;
static std::unique_ptr<hexedit::WindowedScintillaByteSource> g_hexBuffer;

static inline std::size_t hexBufferLength() { return g_hexBuffer ? g_hexBuffer->length() : 0; }
static inline bool        hexBufferEmpty()  { return hexBufferLength() == 0; }
static inline std::uint8_t hexByteAt(std::size_t offset)
{
    if (!g_hexBuffer) return 0;
    std::uint8_t b = 0;
    g_hexBuffer->read(offset, &b, 1);
    return b;
}
static inline std::size_t hexBytesIn(std::size_t offset,
                                       std::size_t count,
                                       std::uint8_t *dest)
{
    if (!g_hexBuffer) return 0;
    return g_hexBuffer->read(offset, dest, count);
}
// Pass-by-reference accessor for HexCore APIs that take `const ByteSource&`
// (findBytePattern, computeByteDiffs, extractRectBytes, formatRectClipboardHex).
// The returned reference is valid until the next bindHexBufferToActiveScintilla()
// call. Consumers MUST guard with hexBufferEmpty() — calling this with no
// buffer bound dereferences null.
static inline const hexedit::ByteSource &hexBufferSource() { return *g_hexBuffer; }

// Forward declarations; defined after LiveSciReader (the concrete SciReader
// that talks to the live host-side Scintilla) is in scope.
static void bindHexBufferToActiveScintilla();
static void invalidateHexBuffer();
static std::set<size_t> bookmarkedRows;
// Compare HEX result mask. Empty when there is no active comparison; otherwise sized to
// max(myLen, otherLen) with `true` at byte offsets that differ between the current buffer
// and the file the user picked.
static std::vector<bool> g_compareDiffs;
static NSString *g_compareOtherPath = nil;
static size_t selectedByteStart = 0;
static size_t selectedByteEnd = 0;
static size_t previewTotalLength = 0;
static NppHandle previewScintillaHandle = 0;
static uintptr_t previewBufferId = 0;
static CGFloat editorBaseFontSize = HEX_FALLBACK_FONT_SIZE;
static NSInteger hexFontZoomDelta = 0;
static bool suppressModificationRefresh = false;

enum class HexCursorField
{
    Hex,
    Ascii
};

static size_t activeByteOffset = 0;
static NSInteger activeHexNibble = 0;
static HexCursorField activeCursorField = HexCursorField::Hex;
static NSInteger asciiAltNumpadValue = -1;

// Most recent values captureScintillaSelection() observed when reading from
// Scintilla. Surfaced via the diagnostic AX element so the XCTest UI suite can
// see *why* a selection-mirroring assertion failed (Scintilla returned no
// selection? returned -1? the handle was nil?). Sentinel -1 means
// "captureScintillaSelection has not yet run for the current preview".
static intptr_t lastScintillaSelStart = -1;
static intptr_t lastScintillaSelEnd = -1;
static intptr_t lastScintillaCaret = -1;
static bool isSelectingBytes = false;
static size_t selectionAnchorByte = 0;

// Rectangular (block) selection state. Mutually exclusive with the linear
// `selectedByteStart`/`selectedByteEnd` pair: when g_rectActive is true, the linear
// selection is empty. The rect's geometry is anchored to the bytesPerRow at creation
// time — changing the row width via the Columns / View-in dialogs clears the rect.
//
// g_rectAnchorOffset is one corner (the byte the user mouseDowned on, or where they
// were positioned when they first pressed Shift+modifier+arrow). The other corner is
// implicit in g_rectSelection's geometry plus activeByteOffset, which always tracks
// the dragged-to byte so the caret renders at the user's pointer.
//
// g_rectOriginField is the pane the drag began in (Hex or Ascii) and is used by the
// copy/paste matrix to tag the clipboard payload with kind = Bytes / Ascii. The address
// column is not selectable — clicking there toggles a bookmark instead.
static hexedit::RectSelection g_rectSelection;
static bool g_rectActive = false;
static bool g_isSelectingRect = false;
static size_t g_rectAnchorOffset = 0;
static HexCursorField g_rectOriginField = HexCursorField::Hex;

static void zoomHexFont(NSInteger delta);
static void resetHexFontZoom();
static void refreshVisibleHexTables();
static NSFont *hexTableFont();
static NSFont *hexHeaderFontFor(NSFont *gridFont);
static CGFloat preciseTextWidth(NSString *text, NSFont *font);
static CGFloat textWidth(NSString *text, NSFont *font);
static CGFloat monospacedGlyphWidth(NSFont *font);
static NSRect textDrawingRect(NSTableView *tableView, NSInteger column, NSInteger row);
static CGFloat asciiGlyphLeft(NSTableView *tableView, NSInteger column, NSInteger row);
static CGFloat cellGlyphLeft(NSTableView *tableView, NSInteger column, NSInteger row, NSFont *font);
static void addHexCellColumns(NSTableView *table, NSFont *font);
static void applyHexTableLayout(NSTableView *table, NSTextField *statusLabel);
static void applyHexViewMode();
static void setHexViewBytesPerCell(int bytesPerCell);
static void toggleHexViewBinary();
static void toggleHexViewEndian();
static void setHexAddressWidth(int width);
static void setHexColumns(int columns);
static int promptHexInteger(NSString *title, NSString *informative, int currentValue, int minValue, int maxValue);
static NSString *promptHexGotoExpression(NSString *defaultText, std::size_t currentOffset, std::size_t totalLength);
static void presentHexValidationError(NSString *message);
static void presentHexGotoDialog();
static void gotoHexOffset(std::size_t offset);
static void presentHexFindDialog(BOOL replaceMode);
static bool executeHexFindNext(hexedit::SearchDirection direction, NSString **errorMessage);
static int executeHexReplaceAll(NSString *findText, NSString *replaceText, bool matchCase, NSString **errorMessage);
static bool executeHexReplaceCurrentSelection(NSString *findText, NSString *replaceText, bool matchCase, NSString **errorMessage);
static void presentInsertColumnsDialog();
static int executeInsertColumns(NSString *patternText, int count, int position, NSString **errorMessage);
static void presentPatternReplaceDialog();
static int executePatternReplace(NSString *patternText, NSString **errorMessage);
static void presentHexCompareDialog();
static int executeHexCompareWithFile(NSString *otherFilePath, NSString **errorMessage);
static void clearHexCompareResult();
static bool compareDiffMaskCellHasDiff(NSInteger row, NSInteger cellIndex);
static bool replaceEditorBytes(size_t offset, const uint8_t *bytes, size_t byteCount, size_t replacedByteCount);
static bool deleteEditorBytes(size_t offset, size_t byteCount);
static bool applyEditorByteTransaction(size_t offset, const uint8_t *bytes, size_t byteCount, size_t replacedByteCount);
static void refreshHexViewFromScintilla(size_t preferredCursorOffset, NSPoint scrollOrigin);
static bool performScintillaUndoRedo(uint32_t message);
static bool canPerformScintillaUndoRedo(uint32_t message);
static void selectedOrCurrentRange(size_t *offset, size_t *byteCount);
static bool copyHexSelectionToPasteboard();
static bool copyHexSelectionAsBinary();
static bool pasteBytesFromPasteboard();
static bool pasteBinaryFromPasteboard();
static bool cutHexSelection();
@class HexClipboardOwner;
static HexClipboardOwner *currentlyOwnedHexSnapshot();
static bool cutHexSelectionBinary();
static bool applyRectBytesPaste(const hexedit::RectSelection &dest,
                                const std::uint8_t *bytes,
                                std::size_t byteCount);

// Custom pasteboard type that carries shape + kind alongside the byte data. When
// the paste path finds this UTI it uses the structured payload directly; when only
// public-text is on the clipboard (e.g. copied from another app), it falls back to
// hexedit::parseRectClipboardText per the user's Q2.b decision.
//
// The wire format is owned by HexCore (kRectPayloadMagic, encodeRectPayload,
// decodeRectPayload) so the same parser the plugin reads can also be exercised
// from libFuzzer harnesses without dragging in AppKit. HexRectClipboardKind below
// is a typedef alias so existing call sites read naturally.
static NSString *const kHexRectPasteboardType = @"org.notepad-plus-plus.HexEditor.rectangular";

using HexRectClipboardKind = hexedit::RectClipboardKind;
static bool deleteHexSelection();
static void selectAllHexBytes();
static bool handleHexDigit(unichar character);
static bool handleBinaryDigit(unichar character);
static bool handleAsciiCharacter(unichar character);
static bool handleAsciiByte(uint8_t byteValue);
static bool handleAsciiAltNumpadDigit(NSEvent *event);
static bool commitAsciiAltNumpadEntry();
static void moveActiveCursor(NSInteger delta);
static void setActiveHexCursor(size_t offset, NSInteger nibble);
static void setActiveAsciiCursor(size_t offset);
static void clampActiveCursor();
static NSInteger cellColumnIndex(NSString *identifier);
static BOOL isVisibleEditableOffset(size_t offset);
static BOOL hasByteSelection();
static BOOL isSelectedByte(size_t offset);
static BOOL hasRectSelection();
static BOOL hasAnyByteSelection();
static size_t currentHighlightRow();
static void clearByteSelection();
static void clearRectSelection();
static void clearAllByteSelections();
static void updateRectSelectionToOffset(size_t endOffset);
static void captureScintillaSelection();
static BOOL isBookmarkedRow(size_t row);
static void toggleBookmarkRow(size_t row);
static uintptr_t getCurrentBufferId();
static bool isPreviewBufferActive();
static NSView *currentEditorView();
static NSView *findScintillaView(NSView *view);
static bool isHexViewActive();
static void updateHexMenuCheck(bool checked);
static NSPoint currentHexTableScrollOrigin();
static void restoreHexTableScrollOrigin(NSPoint origin);
static void restoreHexTableScrollOriginLater(NSPoint origin);
static void resetHexTableScrollOrigin();
static void redrawHexTablePreservingScroll(NSPoint origin);
static void redrawHexRowsPreservingScroll(size_t firstOffset, size_t secondOffset, NSPoint origin);
static NSColor *hexCurrentLineColor();
static NSColor *hexSelectionColor();
static NSColor *hexCurrentLineSelectionColor();
static NSColor *hexCompareDiffColor();
static NSColor *hexCompareDiffTextColor();
static NSColor *hexRegularTextColor();
static NSColor *hexRegularTextBackgroundColor();
static NSColor *hexSelectionTextColor();
static NSColor *hexBookmarkBackgroundColor();
static NSColor *hexBookmarkTextColor();
static NSString *makeStatusText();
static hexedit::DocumentView currentDocumentView();
static hexedit::Selection currentSelection();
static hexedit::CursorState currentCursor();
static void writeBackCursor(const hexedit::CursorState &cursor);

@interface HexTableContainerView : NSView
@end

@implementation HexTableContainerView
- (NSFocusRingType)focusRingType
{
    return NSFocusRingTypeNone;
}

- (void)panelZoomIn
{
    zoomHexFont(1);
}

- (void)panelZoomOut
{
    zoomHexFont(-1);
}

- (void)panelZoomReset
{
    resetHexFontZoom();
}
@end

// Hidden 1×1 view whose AX value reports the current cursor + selection state.
// Format (semicolon-separated key=value pairs, stable contract for the XCTest
// suite): "offset=<size_t>;selStart=<size_t>;selEnd=<size_t>;hasSelection=<0|1>"
// The view is intentionally minuscule and positioned in the corner so it does
// not affect the visible layout; the AX subsystem still reports it via
// accessibilityIdentifier lookup.
@interface HexCursorDiagnosticView : NSView
@end

@implementation HexCursorDiagnosticView
- (BOOL)isAccessibilityElement
{
    return YES;
}
- (NSAccessibilityRole)accessibilityRole
{
    return NSAccessibilityStaticTextRole;
}
- (id)accessibilityValue
{
    // Layout diagnostics — included so the XCTest UI suite can assert that
    // every text-bearing label is sized for its font. statusH is the status
    // label's frame height; statusFontH is the line-height the label needs to
    // render its font without clipping descenders. statusH < statusFontH means
    // letters like 'y' / 'g' / 'p' would have their bottoms cut off.
    CGFloat statusFrameHeight = 0.0;
    CGFloat statusFontLineHeight = 0.0;
    if (hexStatusLabel != nil) {
        statusFrameHeight = NSHeight(hexStatusLabel.frame);
        NSFont *font = hexStatusLabel.font;
        if (font != nil) {
            statusFontLineHeight = ceil(font.ascender - font.descender);
        }
    }
    // Locale diagnostics — what NSLocale.preferredLanguages returns inside the
    // host process. Used to debug the localization cascade XCTest: when the
    // test sets AppleLanguages via `defaults write`, this surface reveals
    // whether the override actually reached NSLocale or was filtered to the
    // system default. Pipe-separated so we can include multi-element arrays
    // inside the semicolon-separated outer format.
    NSArray<NSString *> *nsPrefs = [NSLocale preferredLanguages];
    NSString *nsPrefsJoined = [nsPrefs componentsJoinedByString:@"|"];
    NSArray<NSString *> *userPrefs = hexUserPreferredLanguages();
    NSString *userPrefsJoined = [userPrefs componentsJoinedByString:@"|"];
    // Rect diagnostic fields. rectActive=1 when a rectangular selection is in place;
    // rectOrigin/rectWidth/rectHeight describe its anchor and size in bytes; rectBpr is
    // the bytes-per-row the rect was anchored to (lets a test detect stale rect after
    // the user changes columns). rectOriginPane is "Hex" / "Ascii" so tests can confirm
    // the source-pane tag will travel through to the clipboard.
    NSString *rectOriginPane = (g_rectOriginField == HexCursorField::Ascii) ? @"Ascii" : @"Hex";
    // Header-vs-data alignment match. Set to 1 iff every column's headerCell.alignment
    // equals its dataCell.alignment. The XCUI test asserts this — covers the visual
    // "centered data with left-aligned header" imbalance bug. 0 means at least one
    // column will look unbalanced; the testfailure shouldn't need to dig into which.
    int headerAlignsMatchData = 1;
    if (hexTableView != nil) {
        for (NSTableColumn *col in hexTableView.tableColumns) {
            id dc = col.dataCell;
            id hc = col.headerCell;
            if (![dc respondsToSelector:@selector(alignment)] ||
                ![hc respondsToSelector:@selector(alignment)]) {
                continue;
            }
            if ([dc alignment] != [hc alignment]) {
                headerAlignsMatchData = 0;
                break;
            }
        }
    }
    // Cell + header font sizes (points). Tests verify that when the user
    // zooms in/out via Cmd+/Cmd-/pinch, the header tracks the cell — the
    // headerFont is built off the cell font in hexHeaderFontFor() and any
    // future regression that breaks that link will surface as headerFontPt
    // staying constant while cellFontPt changes.
    CGFloat cellFontPt = 0.0;
    CGFloat headerFontPt = 0.0;
    if (hexTableView != nil && hexTableView.tableColumns.count > 0) {
        NSTableColumn *firstColumn = hexTableView.tableColumns.firstObject;
        if (NSTextFieldCell *dataCell = static_cast<NSTextFieldCell *>(firstColumn.dataCell)) {
            cellFontPt = dataCell.font.pointSize;
        }
        // Read from the attributed-string title's NSFontAttributeName, not
        // headerCell.font directly: AppKit derives header rendering from
        // attributedStringValue, and assigning attributedStringValue can
        // reset the .font property to a system default — so .font is not a
        // reliable proxy for what's actually being drawn.
        NSAttributedString *headerAttr = firstColumn.headerCell.attributedStringValue;
        if (headerAttr.length > 0) {
            NSFont *renderingFont = [headerAttr attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
            if (renderingFont != nil) {
                headerFontPt = renderingFont.pointSize;
            }
        }
        // Fall back to the .font property if no attributed title was set
        // (e.g. a column built before configureTableColumn ran fully).
        if (headerFontPt == 0.0 && firstColumn.headerCell.font != nil) {
            headerFontPt = firstColumn.headerCell.font.pointSize;
        }
    }
    // Caret render geometry — the actual pixel column where drawRect:
    // last painted the caret stripe. Used by rect-drag tests to confirm
    // a known activeByteOffset translates into the expected screen
    // position; the alternative (sampling pixels) is brittle.
    // caretCellMinX is the row-relative X of the cell that contained the
    // caret on its last paint; caretCellOffsetX is (caretX - caretCellMinX),
    // i.e. how far the caret sits inside the cell. Tests assert
    // caretCellOffsetX equals cellGlyphLeft minus column origin, plus
    // (digitInCell × glyphWidth), which means rendering tracks the
    // computed activeByteOffset rather than diverging from it.
    const CGFloat caretCellOffsetX = g_caretLastRenderedValid
        ? (g_caretLastRenderedX - g_caretLastRenderedCellMinX)
        : -1.0;
    // Font-tab toggles. Exposed so tests can confirm the dialog round-
    // trips them through commit + load. Each is a single bit; flagged as
    // a comma-keyed list ("fontFlags=bold,italic,underline,uppercase,mirrorAsciiCursor"
    // each 1/0). Tests pattern-match the prefix to assert specific bits.
    NSString *fontFlags = [NSString stringWithFormat:@"%d,%d,%d,%d,%d",
                              g_fontBold ? 1 : 0,
                              g_fontItalic ? 1 : 0,
                              g_fontUnderline ? 1 : 0,
                              g_uppercaseHex ? 1 : 0,
                              g_mirrorAsciiCursor ? 1 : 0];
    return [NSString stringWithFormat:
            @"offset=%zu;selStart=%zu;selEnd=%zu;hasSelection=%d;statusH=%.1f;statusFontH=%.1f"
            @";sciSelStart=%lld;sciSelEnd=%lld;sciCaret=%lld;preferredLanguages=%@;userPrefs=%@"
            @";rectActive=%d;rectOrigin=%zu;rectWidth=%zu;rectHeight=%zu;rectBpr=%zu;rectOriginPane=%@"
            @";hdrAlignMatch=%d;cellFontPt=%.1f;headerFontPt=%.1f"
            @";caretX=%.1f;caretRow=%ld;caretCellMinX=%.1f;caretCellOffsetX=%.1f"
            @";mirrorWidth=%.1f;fontFlags=%@",
            activeByteOffset, selectedByteStart, selectedByteEnd,
            (selectedByteEnd > selectedByteStart) ? 1 : 0,
            statusFrameHeight, statusFontLineHeight,
            (long long)lastScintillaSelStart,
            (long long)lastScintillaSelEnd,
            (long long)lastScintillaCaret,
            nsPrefsJoined,
            userPrefsJoined,
            g_rectActive ? 1 : 0,
            g_rectSelection.originOffset,
            g_rectSelection.width,
            g_rectSelection.height,
            g_rectSelection.bytesPerRow,
            rectOriginPane,
            headerAlignsMatchData,
            cellFontPt,
            headerFontPt,
            g_caretLastRenderedValid ? g_caretLastRenderedX : -1.0,
            (long)g_caretLastRenderedRow,
            g_caretLastRenderedValid ? g_caretLastRenderedCellMinX : -1.0,
            caretCellOffsetX,
            g_mirrorLastRenderedWidth,
            fontFlags];
}
@end

@interface HexTableScrollView : NSScrollView
@end

@implementation HexTableScrollView {
    // Cumulative magnification across the current trackpad-pinch gesture.
    // NSEvent.magnification arrives in small per-event deltas (~0.01-0.05);
    // we accumulate until a threshold, fire one font-size step, then subtract
    // the threshold so further magnification continues to scale the font.
    CGFloat _pinchAccumulator;
}
- (NSFocusRingType)focusRingType
{
    return NSFocusRingTypeNone;
}

- (void)scrollWheel:(NSEvent *)event
{
    if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
        if (event.scrollingDeltaY > 0) {
            zoomHexFont(1);
        } else if (event.scrollingDeltaY < 0) {
            zoomHexFont(-1);
        }
        return;
    }

    [super scrollWheel:event];
}

// Trackpad pinch-to-zoom. NSScrollView's built-in magnification (allowsMagnification)
// scales the documentView, which would distort the hex grid. We translate pinch
// into discrete font-size steps via zoomHexFont. The threshold + multiplier match
// Scintilla's implementation (notepad-plus-plus-macos/scintilla/cocoa/ScintillaView.mm,
// magnifyWithEvent: at ~line 1321) so users get an identical pinch feel in our
// hex view and in the host's main text editor — that's the whole point: same
// gesture, same response.
- (void)magnifyWithEvent:(NSEvent *)event
{
    _pinchAccumulator += event.magnification * 10.0;
    if (std::abs(_pinchAccumulator) >= 1.0) {
        // Cast truncates toward zero — a 2.5 accumulator fires 2 steps in this
        // event, the .5 remainder is dropped (matches Scintilla's behavior).
        zoomHexFont(static_cast<NSInteger>(_pinchAccumulator));
        _pinchAccumulator = 0.0;
    }
}

- (void)beginGestureWithEvent:(NSEvent *)event
{
#pragma unused(event)
    // Scintilla resets the accumulator at gesture-begin rather than gesture-end;
    // mirror that so a fresh pinch starts from zero regardless of what state the
    // last gesture left behind.
    _pinchAccumulator = 0.0;
}
@end

@interface HexTableDataSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation HexTableDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    NSInteger rows = static_cast<NSInteger>((hexBufferLength() + bpr - 1) / bpr);
    if (hexBufferLength() == previewTotalLength && (hexBufferEmpty() || hexBufferLength() % bpr == 0)) {
        ++rows;
    }
    return rows;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    const int bytesPerRow = currentBytesPerRow();
    const size_t rowOffset = static_cast<size_t>(row) * static_cast<size_t>(bytesPerRow);
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"offset"]) {
        return [NSString stringWithFormat:g_uppercaseHex ? @"%0*zX" : @"%0*zx", g_addressWidth, rowOffset];
    }

    if ([identifier isEqualToString:@"ascii"]) {
        std::string ascii;
        ascii.reserve(static_cast<size_t>(bytesPerRow));
        for (int index = 0; index < bytesPerRow; ++index) {
            const size_t byteIndex = rowOffset + static_cast<size_t>(index);
            if (byteIndex < hexBufferLength()) {
                const uint8_t value = hexByteAt(byteIndex);
                ascii.push_back(std::isprint(value) ? static_cast<char>(value) : '.');
            } else {
                ascii.push_back(' ');
            }
        }
        return [NSString stringWithUTF8String:ascii.c_str()];
    }

    if ([identifier isEqualToString:@"offsetSpacer"] || [identifier isEqualToString:@"spacer"]) {
        return @"";
    }

    if ([identifier hasPrefix:@"cell"]) {
        const NSInteger cellIndex = [[identifier substringFromIndex:4] integerValue];
        const hexedit::ViewMode mode = currentViewMode();
        const size_t firstByte = rowOffset + static_cast<size_t>(cellIndex) * static_cast<size_t>(mode.bytesPerCell);
        if (firstByte >= hexBufferLength()) {
            return @"";
        }
        const size_t available = std::min(static_cast<size_t>(mode.bytesPerCell), hexBufferLength() - firstByte);
        // formatCell reads at most ViewMode.bytesPerCell bytes (≤ 8). Fetch
        // into a stack scratch buffer so we don't depend on hexBufferData()
        // returning a raw pointer — Step 2c is migrating the storage to a
        // page-cached Scintilla reader where no such pointer is exposed.
        std::uint8_t scratch[8];
        const size_t got = hexBytesIn(firstByte, available, scratch);
        std::string formatted = hexedit::formatCell(scratch, got, mode);
        return [NSString stringWithUTF8String:formatted.c_str()];
    }

    return @"";
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (![cell isKindOfClass:[NSTextFieldCell class]]) {
        return;
    }

    NSTextFieldCell *textCell = static_cast<NSTextFieldCell *>(cell);
    // Regular cells never paint a background of their own — the row-level
    // current-line highlight (drawn beneath in drawRect:) needs to show
    // through. The "Regular Text Background" preference applies at the
    // table-canvas level (table.backgroundColor) instead, so it covers
    // the entire pane uniformly. Compare-diff and bookmark below override
    // intentionally — those highlights are meant to mask the row colour.
    textCell.drawsBackground = NO;
    textCell.backgroundColor = nil;
    textCell.textColor = hexRegularTextColor();

    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"offset"] && isBookmarkedRow(static_cast<size_t>(row))) {
        textCell.drawsBackground = YES;
        textCell.backgroundColor = hexBookmarkBackgroundColor();
        textCell.textColor = hexBookmarkTextColor();
    } else if ([identifier hasPrefix:@"cell"]) {
        const NSInteger cellIdx = [[identifier substringFromIndex:4] integerValue];
        if (!g_compareDiffs.empty() && compareDiffMaskCellHasDiff(row, cellIdx)) {
            textCell.drawsBackground = YES;
            textCell.backgroundColor = hexCompareDiffColor();
            textCell.textColor = hexCompareDiffTextColor();
        }
        // Selection text colour overrides any per-cell foreground above.
        // The selection background is painted by drawRect: as a rectangle
        // beneath the cell text; setting textColor here makes the byte
        // glyphs render in the user's chosen Selection-Text colour on top
        // of that rectangle. Matches the Windows plugin's recolouring.
        if ([self cellInSelectionAtRow:row cellIndex:cellIdx]) {
            textCell.textColor = hexSelectionTextColor();
        }
    } else if ([identifier isEqualToString:@"ascii"]) {
        // ASCII pane: one cell per row containing all bpr characters as a
        // single string. Plain `textColor` would paint every glyph the same
        // colour, which is wrong inside a partial selection — the chars
        // outside the selection should stay in regular-text colour, the
        // chars inside should match Selection-Text. Switch to an attributed
        // string with per-character foreground attrs only when there's an
        // active selection (avoids the allocation in the common case).
        if (hasByteSelection() || hasRectSelection()) {
            NSString *plain = textCell.stringValue ?: @"";
            const NSUInteger len = plain.length;
            if (len > 0) {
                NSMutableAttributedString *attr = [[[NSMutableAttributedString alloc] initWithString:plain] autorelease];
                NSRange whole = NSMakeRange(0, len);
                [attr addAttribute:NSForegroundColorAttributeName value:hexRegularTextColor() range:whole];
                if (textCell.font) {
                    [attr addAttribute:NSFontAttributeName value:textCell.font range:whole];
                }
                if (g_fontUnderline) {
                    [attr addAttribute:NSUnderlineStyleAttributeName
                                  value:@(NSUnderlineStyleSingle)
                                  range:whole];
                }
                NSColor *selFg = hexSelectionTextColor();
                for (NSUInteger b = 0; b < len; b++) {
                    if ([self asciiByteInSelectionAtRow:row byteInRow:(NSInteger)b]) {
                        [attr addAttribute:NSForegroundColorAttributeName value:selFg range:NSMakeRange(b, 1)];
                    }
                }
                textCell.attributedStringValue = attr;
            }
        }
    }

    // Underline pass: NSTextFieldCell has no underline property, so the
    // only way to draw underlined glyphs is via NSAttributedString with
    // NSUnderlineStyleAttributeName. When the Font tab's underline toggle
    // is on, we wrap whatever stringValue the cell ended up with into a
    // freshly built attributed string carrying the cell's current font
    // / textColor / underline. Skipped when the ASCII branch above
    // already produced an attributed string (it folded the underline in
    // there to keep the per-byte selection-fg recolouring working).
    if (g_fontUnderline && ![identifier isEqualToString:@"offsetSpacer"] && ![identifier isEqualToString:@"spacer"]) {
        NSAttributedString *existingAttr = textCell.attributedStringValue;
        const BOOL alreadyAttributed = (existingAttr.length > 0) &&
            [existingAttr attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] != nil;
        if (!alreadyAttributed) {
            NSString *plain = textCell.stringValue ?: @"";
            if (plain.length > 0 && textCell.font) {
                NSDictionary *attrs = @{
                    NSFontAttributeName: textCell.font,
                    NSForegroundColorAttributeName: textCell.textColor ?: [NSColor textColor],
                    NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                };
                textCell.attributedStringValue =
                    [[[NSAttributedString alloc] initWithString:plain attributes:attrs] autorelease];
            }
        }
    }
}

// Per-byte selection check for the ASCII pane. The cellInSelectionAtRow:cellIndex:
// helper above works on bytes-per-cell groupings (the hex pane's column
// granularity); ASCII renders one glyph per byte, so we need a byte-level
// version. Handles both linear (selectedByteStart..selectedByteEnd) and
// rectangular (g_rectSelection) selection modes the same way the hex pane
// does — keeping the two visualisations in sync.
- (BOOL)asciiByteInSelectionAtRow:(NSInteger)row byteInRow:(NSInteger)byteInRow
{
    if (!hasByteSelection() && !hasRectSelection()) return NO;
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    if ((size_t)byteInRow >= bpr) return NO;
    const size_t byteOffset = static_cast<size_t>(row) * bpr + static_cast<size_t>(byteInRow);
    if (hasRectSelection()) {
        const size_t rectFirstRow = g_rectSelection.originOffset / bpr;
        const size_t rectLastRow = rectFirstRow + g_rectSelection.height - 1;
        if (static_cast<size_t>(row) < rectFirstRow || static_cast<size_t>(row) > rectLastRow) return NO;
        const size_t rectCol0 = g_rectSelection.originOffset % bpr;
        const size_t rectColEnd = rectCol0 + g_rectSelection.width;  // exclusive
        return static_cast<size_t>(byteInRow) >= rectCol0 && static_cast<size_t>(byteInRow) < rectColEnd;
    }
    return byteOffset >= selectedByteStart && byteOffset < selectedByteEnd;
}

// True iff the cell at (row, cellIndex) overlaps the current selection
// (linear or rectangular). Used by willDisplayCell to recolour the byte
// glyphs in the user's chosen Selection-Text colour. Cell range is
// [cellIndex * bpc, (cellIndex + 1) * bpc) bytes within the row.
- (BOOL)cellInSelectionAtRow:(NSInteger)row cellIndex:(NSInteger)cellIndex
{
    if (!hasByteSelection() && !hasRectSelection()) return NO;
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    const size_t bpc = static_cast<size_t>(std::max(g_bytesPerCell, 1));
    const size_t rowFirst = static_cast<size_t>(row) * bpr;
    const size_t cellFirst = rowFirst + static_cast<size_t>(cellIndex) * bpc;
    const size_t cellEnd = cellFirst + bpc;  // exclusive

    if (hasRectSelection()) {
        const size_t rectFirstRow = g_rectSelection.originOffset / bpr;
        const size_t rectLastRow = rectFirstRow + g_rectSelection.height - 1;
        if (static_cast<size_t>(row) < rectFirstRow || static_cast<size_t>(row) > rectLastRow) return NO;
        const size_t rectCol0 = g_rectSelection.originOffset % bpr;
        const size_t rectColEnd = rectCol0 + g_rectSelection.width;  // exclusive
        const size_t cellCol0 = static_cast<size_t>(cellIndex) * bpc;
        const size_t cellColEnd = cellCol0 + bpc;
        return cellCol0 < rectColEnd && cellColEnd > rectCol0;
    }
    return cellFirst < selectedByteEnd && cellEnd > selectedByteStart;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return NO;
}
@end

static HexTableDataSource *hexTableDataSource = nil;

// Header view that paints its background to match the table's data-row
// background (windowBackgroundColor) instead of the system's default
// header chrome (a darker control gray that doesn't match the surrounding
// pane in light mode). We don't call super.drawRect because that draws
// the chrome we're trying to avoid; instead we fill the column-occupied
// span with the row colour and call drawInteriorWithFrame: on each
// headerCell to render just the title text.
@interface HexTableHeaderView : NSTableHeaderView
@end

@implementation HexTableHeaderView
- (void)drawRect:(NSRect)dirtyRect
{
    NSColor *bg = self.tableView.backgroundColor ?: [NSColor windowBackgroundColor];
    [bg set];
    NSRectFill(dirtyRect);

    const NSInteger numCols = self.tableView.numberOfColumns;
    for (NSInteger i = 0; i < numCols; ++i) {
        const NSRect cellRect = [self headerRectOfColumn:i];
        if (!NSIntersectsRect(cellRect, dirtyRect)) {
            continue;
        }
        NSTableColumn *col = [self.tableView.tableColumns objectAtIndex:i];
        // drawInteriorWithFrame: renders the title text without the
        // headerCell's own chrome (background + bottom rule). The bg
        // fill above sits behind every column, so spacers paint as
        // empty same-colour strips matching the data rows beneath.
        [col.headerCell drawInteriorWithFrame:cellRect inView:self];
    }
}
@end

@interface HexTableView : NSTableView
@end

@implementation HexTableView
- (NSFocusRingType)focusRingType
{
    return NSFocusRingTypeNone;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

// Intercept the hex-specific keyboard shortcuts BEFORE the host's main menu gets a chance.
// AppKit dispatches performKeyEquivalent: to the key window's view tree first, then to the
// menu bar; the host's Edit menu binds Cmd+F / Cmd+G to its own Find actions, so without
// this override our keyDown handler would never see those events.
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (![self isHexTableView_acceptsHexShortcut:event]) {
        return [super performKeyEquivalent:event];
    }

    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 0) {
        return [super performKeyEquivalent:event];
    }
    const unichar c = [characters characterAtIndex:0];
    const NSEventModifierFlags mods = event.modifierFlags;

    if (c == 'f' || c == 'F') {
        presentHexFindDialog((mods & NSEventModifierFlagOption) != 0);
        return YES;
    }
    if (c == 'g' || c == 'G') {
        NSString *err = nil;
        const hexedit::SearchDirection dir = ((mods & NSEventModifierFlagShift) != 0)
            ? hexedit::SearchDirection::Backward
            : hexedit::SearchDirection::Forward;
        if (!executeHexFindNext(dir, &err)) {
            presentHexValidationError(err ?: L(@"find.errorNotFound"));
        }
        return YES;
    }
    if (c == 'l' || c == 'L') {
        presentHexGotoDialog();
        return YES;
    }
    // Wire Cmd-X / Cmd-C / Cmd-V / Cmd-A to our cut: / copy: / paste: /
    // selectAll: responder methods. Without this, AppKit dispatches the
    // keyboard shortcut to the host's Edit menu — whose targets are tied
    // to NPP's text-editor selection, not the hex view's byte selection.
    // Bug fingerprint when this isn't claimed: Cmd-C does nothing visible
    // (clipboard stays whatever was there before), and the next Cmd-V
    // pastes that *stale* clipboard, looking like the source copy "got
    // the wrong bytes". Only the bare-Command variants are claimed —
    // shift/option-modified shortcuts (e.g. Cmd-Shift-V "paste and match
    // style") fall through to whatever the host wires them to.
    const NSEventModifierFlags clipMask =
        NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;
    if ((mods & clipMask) == 0) {
        if (c == 'c' || c == 'C') { [self copy:nil];      return YES; }
        if (c == 'x' || c == 'X') { [self cut:nil];       return YES; }
        if (c == 'v' || c == 'V') { [self paste:nil];     return YES; }
        if (c == 'a' || c == 'A') { [self selectAll:nil]; return YES; }
    }
    return [super performKeyEquivalent:event];
}

// Helper: only claim shortcut events when this view (or its window) is plausibly the
// active hex view. Without the gate, every unrelated Cmd+F in the host would route here.
- (BOOL)isHexTableView_acceptsHexShortcut:(NSEvent *)event
{
    if ((event.modifierFlags & NSEventModifierFlagCommand) == 0) {
        return NO;
    }
    NSWindow *window = self.window;
    if (window == nil) {
        return NO;
    }
    // The hex table only becomes a window subview when the overlay is visible.
    return self.superview != nil;
}

- (void)drawRect:(NSRect)dirtyRect
{
    const NSInteger firstVisibleRow = std::max<NSInteger>(0, [self rowAtPoint:NSMakePoint(NSMinX(dirtyRect), NSMinY(dirtyRect))]);
    NSInteger lastVisibleRow = [self rowAtPoint:NSMakePoint(NSMinX(dirtyRect), NSMaxY(dirtyRect))];
    if (lastVisibleRow < 0) {
        lastVisibleRow = self.numberOfRows - 1;
    }

    const NSInteger offsetColumn = [self columnWithIdentifier:@"offset"];
    const NSInteger asciiColumn = [self columnWithIdentifier:@"ascii"];
    const size_t highlightRow = currentHighlightRow();

    for (NSInteger rowIndex = firstVisibleRow; rowIndex <= lastVisibleRow && rowIndex < self.numberOfRows; ++rowIndex) {
        const NSRect rowRect = [self rectOfRow:rowIndex];
        if (!NSIntersectsRect(dirtyRect, rowRect)) {
            continue;
        }

        if (static_cast<size_t>(rowIndex) == highlightRow) {
            [hexCurrentLineColor() setFill];
            NSRect highlightRect = rowRect;
            if (asciiColumn >= 0) {
                NSFont *font = hexTableFont();
                NSRect asciiFrame = [self frameOfCellAtColumn:asciiColumn row:rowIndex];
                const CGFloat asciiEndX = asciiGlyphLeft(self, asciiColumn, rowIndex) + (static_cast<CGFloat>(currentBytesPerRow()) * monospacedGlyphWidth(font));
                highlightRect.size.width = std::max<CGFloat>(asciiEndX - NSMinX(highlightRect), 0.0);
                highlightRect = NSIntersectionRect(highlightRect, NSUnionRect(rowRect, asciiFrame));
            }
            NSRectFillUsingOperation(highlightRect, NSCompositingOperationSourceOver);
        }

        const size_t bpr = static_cast<size_t>(currentBytesPerRow());
        const size_t rowStart = static_cast<size_t>(rowIndex) * bpr;
        const size_t rowEnd = rowStart + bpr;

        // Compute the byte range to highlight in this row. Linear and rectangular
        // selections are mutually exclusive (the selection helpers enforce that), so
        // we only enter one branch here. Both branches end in the same per-row
        // highlight code below — only the [firstByteInRow, lastByteInRow] range differs.
        size_t firstByteInRow = 0;
        size_t lastByteInRow = 0;
        bool drawHighlight = false;
        if (hasRectSelection()) {
            const size_t rectFirstRow = g_rectSelection.originOffset / bpr;
            const size_t rectLastRow = rectFirstRow + g_rectSelection.height - 1;
            const size_t rectCol0 = g_rectSelection.originOffset % bpr;
            const size_t rectColN = rectCol0 + g_rectSelection.width - 1;
            if (static_cast<size_t>(rowIndex) >= rectFirstRow && static_cast<size_t>(rowIndex) <= rectLastRow) {
                firstByteInRow = rectCol0;
                lastByteInRow = std::min(rectColN, bpr - 1);
                drawHighlight = true;
            }
        } else if (hasByteSelection() && selectedByteEnd > rowStart && selectedByteStart < rowEnd) {
            const size_t selectedRowStart = std::max(selectedByteStart, rowStart);
            const size_t selectedRowEnd = std::min(selectedByteEnd, rowEnd);
            firstByteInRow = selectedRowStart % bpr;
            lastByteInRow = (selectedRowEnd - 1) % bpr;
            drawHighlight = true;
        }
        if (!drawHighlight) {
            continue;
        }

        [(static_cast<size_t>(rowIndex) == highlightRow ? hexCurrentLineSelectionColor() : hexSelectionColor()) setFill];
        NSFont *font = hexTableFont();
        const CGFloat charWidth = monospacedGlyphWidth(font);
        const hexedit::ViewMode mode = currentViewMode();
        const int bpc = std::max(mode.bytesPerCell, 1);
        const int digitsPerByte = (mode.notation == hexedit::CellNotation::Binary) ? 8 : 2;
        const size_t firstCell = firstByteInRow / static_cast<size_t>(bpc);
        const size_t lastCell = lastByteInRow / static_cast<size_t>(bpc);

        const NSInteger firstHexColumn = [self columnWithIdentifier:[NSString stringWithFormat:@"cell%02zu", firstCell]];
        const NSInteger lastHexColumn = [self columnWithIdentifier:[NSString stringWithFormat:@"cell%02zu", lastCell]];
        if (firstHexColumn >= 0 && lastHexColumn >= 0) {
            NSRect firstHexFrame = [self frameOfCellAtColumn:firstHexColumn row:rowIndex];
            const CGFloat cellTextPx = static_cast<CGFloat>(digitsPerByte * bpc) * charWidth;
            const CGFloat startX = cellGlyphLeft(self, firstHexColumn, rowIndex, font);
            const CGFloat endX = cellGlyphLeft(self, lastHexColumn, rowIndex, font) + cellTextPx;
            NSRect hexSelectionRect = NSMakeRect(startX, NSMinY(firstHexFrame), endX - startX, NSHeight(firstHexFrame));
            NSRectFillUsingOperation(hexSelectionRect, NSCompositingOperationSourceOver);
        }

        if (asciiColumn >= 0) {
            NSRect asciiFrame = [self frameOfCellAtColumn:asciiColumn row:rowIndex];
            const CGFloat asciiGlyphOrigin = asciiGlyphLeft(self, asciiColumn, rowIndex);
            const CGFloat asciiStartX = asciiGlyphOrigin + static_cast<CGFloat>(firstByteInRow) * charWidth;
            const CGFloat asciiEndX = asciiGlyphOrigin + static_cast<CGFloat>(lastByteInRow + 1) * charWidth;
            NSRect asciiSelectionRect = NSMakeRect(asciiStartX, NSMinY(asciiFrame), asciiEndX - asciiStartX, NSHeight(asciiFrame));
            NSRectFillUsingOperation(asciiSelectionRect, NSCompositingOperationSourceOver);
        }
    }

    [super drawRect:dirtyRect];

    // Reset per-paint diagnostic stashes BEFORE the early-return below
    // so an invalidated caret doesn't leave stale values from the prior
    // paint visible to tests. Set to true / non-zero only when this
    // paint actually draws something.
    g_caretLastRenderedValid = false;
    g_mirrorLastRenderedWidth = 0.0;

    if (!isVisibleEditableOffset(activeByteOffset)) {
        return;
    }

    const size_t caretBpr = static_cast<size_t>(currentBytesPerRow());
    const bool drawAsciiCaretAtLineEnd = hasByteSelection() &&
        activeCursorField == HexCursorField::Ascii &&
        selectedByteEnd > selectedByteStart &&
        selectedByteEnd == activeByteOffset &&
        (selectedByteEnd % caretBpr) == 0;
    // Linear-drag caret convention (set 2026-05-04 to match Windows):
    // while the user is mid-drag (isSelectingBytes), the caret is rendered
    // flush against the right edge of the LAST selected byte — no gap
    // between the selection wash and the caret stripe. After mouseUp the
    // caret falls through to its normal activeByteOffset = selectedByteEnd
    // position, which sits at byte (selectedByteEnd)'s left edge (one
    // inter-cell gap to the right of the selection, "at the beginning of
    // the next byte"). The "during" branch picks up by adjusting the
    // caret-target byte to (selectedByteEnd - 1) and engaging the same
    // right-edge shift used by rect-mode. drawAsciiCaretAtLineEnd remains
    // a special case for ASCII end-of-row even outside an active drag.
    const bool inLinearMouseDrag = isSelectingBytes &&
        hasByteSelection() &&
        selectedByteEnd > selectedByteStart &&
        selectedByteEnd == activeByteOffset &&
        selectedByteEnd > 0;
    const bool useLinearDragCaretByte = inLinearMouseDrag;
    const size_t caretByteOffset = (drawAsciiCaretAtLineEnd || useLinearDragCaretByte)
        ? selectedByteEnd - 1
        : activeByteOffset;
    const NSInteger row = static_cast<NSInteger>(caretByteOffset / caretBpr);
    if (row < 0 || row >= self.numberOfRows || !NSIntersectsRect(dirtyRect, [self rectOfRow:row])) {
        return;
    }

    NSFont *font = hexTableFont();
    CGFloat caretX = 0.0;
    NSRect cellFrame = NSZeroRect;

    if (activeCursorField == HexCursorField::Hex) {
        const hexedit::ViewMode mode = currentViewMode();
        const size_t byteInRow = caretByteOffset % caretBpr;
        const hexedit::DisplayPosition pos = hexedit::displayPositionForByte(byteInRow, static_cast<int>(activeHexNibble), mode);
        const NSInteger tableColumn = [self columnWithIdentifier:[NSString stringWithFormat:@"cell%02zu", pos.cellIndex]];
        if (tableColumn < 0) {
            return;
        }

        cellFrame = [self frameOfCellAtColumn:tableColumn row:row];
        const CGFloat glyphWidth = monospacedGlyphWidth(font);
        caretX = cellGlyphLeft(self, tableColumn, row, font) + (static_cast<CGFloat>(pos.digitInCell) * glyphWidth);

        // Right-edge shift: the caret renders flush against the right edge
        // of the byte under it instead of at its left edge. Engaged in two
        // scenarios:
        //   - Linear mouse drag in progress (caretByteOffset was already
        //     reset to selectedByteEnd-1 above, so this just slides the
        //     caret stripe past the byte's digits to sit visually on
        //     top of the rightmost edge of the selection wash).
        //   - Rect selection where the active corner sits on the rect's
        //     right column (drag-right / keyboard-extend-right). Same
        //     visual outcome as linear; the user can't tell rect from
        //     linear by where the caret renders.
        // For rect drag-LEFT (active corner == rect left), no shift; the
        // caret stays at the byte's left edge so it sits before the
        // selection wash, mirror-image of drag-right.
        bool applyRightEdgeShift = useLinearDragCaretByte;
        if (hasRectSelection() && !applyRightEdgeShift) {
            const size_t rectColStart = g_rectSelection.originOffset % caretBpr;
            const size_t rectColEnd = rectColStart + g_rectSelection.width - 1;
            if (byteInRow == rectColEnd && rectColEnd > rectColStart) {
                applyRightEdgeShift = true;
            }
        }
        if (applyRightEdgeShift) {
            const int totalDigits = std::max(hexedit::digitsPerCell(mode), 1);
            caretX += static_cast<CGFloat>(totalDigits - pos.digitInCell) * glyphWidth;
        }
    } else {
        const NSInteger tableColumn = [self columnWithIdentifier:@"ascii"];
        if (tableColumn < 0) {
            return;
        }

        cellFrame = [self frameOfCellAtColumn:tableColumn row:row];
        const CGFloat charWidth = monospacedGlyphWidth(font);
        const size_t asciiColumnIndex = drawAsciiCaretAtLineEnd ? caretBpr : (caretByteOffset % caretBpr);
        caretX = asciiGlyphLeft(self, tableColumn, row) + static_cast<CGFloat>(asciiColumnIndex) * charWidth;

        // Same right-edge shift logic as the hex pane (linear drag flush
        // and rect right-corner). ASCII has one glyph per byte, so the
        // shift is exactly one charWidth. drawAsciiCaretAtLineEnd already
        // landed the caret at column index = caretBpr above (visually the
        // end of the row), so don't double-shift in that case.
        if (!drawAsciiCaretAtLineEnd) {
            bool applyAsciiRightEdgeShift = useLinearDragCaretByte;
            if (hasRectSelection() && !applyAsciiRightEdgeShift) {
                const size_t rectColStart = g_rectSelection.originOffset % caretBpr;
                const size_t rectColEnd = rectColStart + g_rectSelection.width - 1;
                const size_t activeCol = caretByteOffset % caretBpr;
                if (activeCol == rectColEnd && rectColEnd > rectColStart) {
                    applyAsciiRightEdgeShift = true;
                }
            }
            if (applyAsciiRightEdgeShift) {
                caretX += charWidth;
            }
        }
    }

    NSRect caretRect = NSMakeRect(caretX, NSMinY(cellFrame) + 2.0, HEX_CARET_WIDTH, std::max<CGFloat>(NSHeight(cellFrame) - 4.0, 1.0));
    [[NSColor selectedContentBackgroundColor] setFill];
    NSRectFill(caretRect);
    // Stash the caret's last-rendered X / row / cell origin for the
    // diagnostic AX surface so UI tests can assert that a known cursor /
    // rect-selection state translates into the expected pixel placement.
    // This is the only signal the test harness has of where the caret was
    // drawn (custom NSRectFill output is invisible to AX).
    g_caretLastRenderedX = caretX;
    g_caretLastRenderedRow = row;
    g_caretLastRenderedCellMinX = NSMinX(cellFrame);
    g_caretLastRenderedValid = true;

    // Mirror Cursor: draw a hollow rectangle in the OPPOSITE pane around
    // the byte the caret is currently associated with. Cross-references
    // hex digits with their ASCII characters at a glance, so the user
    // doesn't have to count columns to find the matching glyph in the
    // other pane. Gated on the Font tab toggle (g_mirrorAsciiCursor).
    // Skipped if caretByteOffset is past the last selected/visible byte
    // (the caret-render block above already returned in that case for
    // out-of-bounds offsets, but we re-check the resolved byte here so a
    // forward-linear post-mouseUp caret at byte "selEnd" — which can be
    // exactly at totalLength — doesn't draw a mirror box around a byte
    // that doesn't exist yet).
    // Suppress the mirror rectangle whenever any selection is active —
    // linear or rectangular. The selection wash already gives the user a
    // visual cross-reference (both panes show the highlighted bytes); a
    // hollow rectangle on top would clutter the display rather than aid
    // navigation. The mirror is most useful for free-roaming caret
    // movement (no selection), which is when this branch fires.
    if (g_mirrorAsciiCursor && caretByteOffset < previewTotalLength
        && !hasByteSelection() && !hasRectSelection()) {
        NSColor *mirrorColor = [[NSColor selectedContentBackgroundColor] colorWithAlphaComponent:0.55];
        [mirrorColor setStroke];
        const size_t byteInRow = caretByteOffset % caretBpr;
        if (activeCursorField == HexCursorField::Hex) {
            // Mirror into the ASCII pane: outline the one ASCII char
            // corresponding to the caret byte.
            const NSInteger asciiCol = [self columnWithIdentifier:@"ascii"];
            if (asciiCol >= 0) {
                NSRect asciiCellFrame = [self frameOfCellAtColumn:asciiCol row:row];
                const CGFloat asciiOriginX = asciiGlyphLeft(self, asciiCol, row);
                const CGFloat charWidth = monospacedGlyphWidth(font);
                NSRect mirrorRect = NSMakeRect(asciiOriginX + static_cast<CGFloat>(byteInRow) * charWidth,
                                                 NSMinY(asciiCellFrame) + 1.0,
                                                 charWidth,
                                                 std::max<CGFloat>(NSHeight(asciiCellFrame) - 2.0, 1.0));
                NSFrameRectWithWidth(mirrorRect, 1.0);
                g_mirrorLastRenderedWidth = NSWidth(mirrorRect);
            }
        } else {
            // Mirror into the hex pane: outline JUST the caret byte's
            // digits within its hex cell. For bpc > 1 the cell holds
            // multiple bytes; we pick the byte at the cell's
            // little/big-endian-aware sub-position so the outline
            // tracks the actual visible digits in the displayed order.
            const hexedit::ViewMode mode = currentViewMode();
            const hexedit::DisplayPosition pos = hexedit::displayPositionForByte(byteInRow, 0, mode);
            const NSInteger hexCol = [self columnWithIdentifier:[NSString stringWithFormat:@"cell%02zu", pos.cellIndex]];
            if (hexCol >= 0) {
                NSRect hexCellFrame = [self frameOfCellAtColumn:hexCol row:row];
                const CGFloat hexGlyphLeftX = cellGlyphLeft(self, hexCol, row, font);
                const CGFloat glyphWidth = monospacedGlyphWidth(font);
                const int totalDigits = std::max(hexedit::digitsPerCell(mode), 1);
                const int bpc = std::max(mode.bytesPerCell, 1);
                const int digitsPerByte = totalDigits / bpc;
                // pos.digitInCell is the first digit of the *active*
                // sub-byte (we asked with subInByte=0). Its position
                // already accounts for endianness via the displayed-byte
                // mapping in displayPositionForByte.
                const CGFloat byteX = hexGlyphLeftX + static_cast<CGFloat>(pos.digitInCell) * glyphWidth;
                NSRect mirrorRect = NSMakeRect(byteX,
                                                 NSMinY(hexCellFrame) + 1.0,
                                                 static_cast<CGFloat>(digitsPerByte) * glyphWidth,
                                                 std::max<CGFloat>(NSHeight(hexCellFrame) - 2.0, 1.0));
                NSFrameRectWithWidth(mirrorRect, 1.0);
                g_mirrorLastRenderedWidth = NSWidth(mirrorRect);
            }
        }
    }
}

- (NSPoint)currentScrollOrigin
{
    return self.enclosingScrollView.contentView.bounds.origin;
}

- (void)restoreScrollOrigin:(NSPoint)origin
{
    NSClipView *clipView = self.enclosingScrollView.contentView;
    [clipView scrollToPoint:origin];
    [self.enclosingScrollView reflectScrolledClipView:clipView];
}

- (void)reloadDataPreservingScrollOrigin:(NSPoint)origin
{
    [self reloadData];
    [self restoreScrollOrigin:origin];
    restoreHexTableScrollOriginLater(origin);
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    size_t byteOffset = 0;
    NSInteger nibble = 0;
    HexCursorField field = activeCursorField;
    // Only reposition the caret on right-click when nothing is selected. With a
    // linear OR rectangular selection active, a right-click that moved the caret
    // would let the user lose track of which bytes Cut/Copy/Delete will operate
    // on — the menu fires on the still-active selection, not on the right-click
    // point.
    if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field] && !hasAnyByteSelection()) {
        if (field == HexCursorField::Hex) {
            setActiveHexCursor(byteOffset, nibble);
        } else {
            setActiveAsciiCursor(byteOffset);
        }
        [self setNeedsDisplay:YES];
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:L(@"app.title")];
    NSMenuItem *undoItem = [menu addItemWithTitle:L(@"menu.context.undo") action:@selector(undo:) keyEquivalent:@""];
    undoItem.target = self;
    NSMenuItem *redoItem = [menu addItemWithTitle:L(@"menu.context.redo") action:@selector(redo:) keyEquivalent:@""];
    redoItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    // Cmd-X / Cmd-C / Cmd-V shortcuts shown in the context menu so the user
    // sees the binding next to each item. The actual key dispatch is handled
    // in HexTableView.performKeyEquivalent: — these strings exist primarily
    // for display, but AppKit will also dispatch the shortcut to these items
    // if the menu is the receiving responder, which is harmless redundancy.
    NSMenuItem *cutItem = [menu addItemWithTitle:L(@"menu.context.cut") action:@selector(hexCut:) keyEquivalent:@"x"];
    cutItem.target = self;
    NSMenuItem *copyItem = [menu addItemWithTitle:L(@"menu.context.copy") action:@selector(hexCopy:) keyEquivalent:@"c"];
    copyItem.target = self;
    NSMenuItem *pasteItem = [menu addItemWithTitle:L(@"menu.context.paste") action:@selector(hexPaste:) keyEquivalent:@"v"];
    pasteItem.target = self;
    NSMenuItem *deleteItem = [menu addItemWithTitle:L(@"menu.context.delete") action:@selector(hexDelete:) keyEquivalent:@""];
    deleteItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cutBinaryItem = [menu addItemWithTitle:L(@"menu.context.cutBinary") action:@selector(hexCutBinary:) keyEquivalent:@""];
    cutBinaryItem.target = self;
    NSMenuItem *copyBinaryItem = [menu addItemWithTitle:L(@"menu.context.copyBinary") action:@selector(hexCopyBinary:) keyEquivalent:@""];
    copyBinaryItem.target = self;
    NSMenuItem *pasteBinaryItem = [menu addItemWithTitle:L(@"menu.context.pasteBinary") action:@selector(hexPasteBinary:) keyEquivalent:@""];
    pasteBinaryItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *findItem = [menu addItemWithTitle:L(@"menu.context.find") action:@selector(hexShowFindDialog:) keyEquivalent:@"f"];
    findItem.target = self;
    findItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem *findReplaceItem = [menu addItemWithTitle:L(@"menu.context.findReplace") action:@selector(hexShowFindReplaceDialog:) keyEquivalent:@"f"];
    findReplaceItem.target = self;
    findReplaceItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    NSMenuItem *findNextItem = [menu addItemWithTitle:L(@"menu.context.findNext") action:@selector(hexFindNext:) keyEquivalent:@"g"];
    findNextItem.target = self;
    findNextItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem *findPrevItem = [menu addItemWithTitle:L(@"menu.context.findPrevious") action:@selector(hexFindPrevious:) keyEquivalent:@"g"];
    findPrevItem.target = self;
    findPrevItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *gotoItem = [menu addItemWithTitle:L(@"menu.context.gotoOffset") action:@selector(hexShowGotoDialog:) keyEquivalent:@"l"];
    gotoItem.target = self;
    gotoItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *viewItem = [menu addItemWithTitle:L(@"menu.context.viewIn") action:nil keyEquivalent:@""];
    NSMenu *viewSubmenu = [[NSMenu alloc] initWithTitle:L(@"menu.context.viewIn")];
    struct BitsEntry { NSString *title; int bytesPerCell; SEL selector; };
    BitsEntry entries[] = {
        { L(@"menu.viewIn.bits8"),  1, @selector(hexViewSet8Bit:) },
        { L(@"menu.viewIn.bits16"), 2, @selector(hexViewSet16Bit:) },
        { L(@"menu.viewIn.bits32"), 4, @selector(hexViewSet32Bit:) },
        { L(@"menu.viewIn.bits64"), 8, @selector(hexViewSet64Bit:) },
    };
    for (const auto &entry : entries) {
        NSMenuItem *bitsItem = [viewSubmenu addItemWithTitle:entry.title action:entry.selector keyEquivalent:@""];
        bitsItem.target = self;
        bitsItem.state = (g_bytesPerCell == entry.bytesPerCell) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [viewSubmenu addItem:[NSMenuItem separatorItem]];
    NSString *binaryTitle = (g_notation == hexedit::CellNotation::Binary)
        ? L(@"menu.viewIn.toHex")
        : L(@"menu.viewIn.toBinary");
    NSMenuItem *binaryItem = [viewSubmenu addItemWithTitle:binaryTitle action:@selector(hexViewToggleBinary:) keyEquivalent:@""];
    binaryItem.target = self;
    if (g_bytesPerCell > 1) {
        NSString *endianTitle = g_littleEndian
            ? L(@"menu.viewIn.toBigEndian")
            : L(@"menu.viewIn.toLittleEndian");
        NSMenuItem *endianItem = [viewSubmenu addItemWithTitle:endianTitle action:@selector(hexViewToggleEndian:) keyEquivalent:@""];
        endianItem.target = self;
    }
    viewItem.submenu = viewSubmenu;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *addrItem = [menu addItemWithTitle:L(@"menu.context.addressWidth") action:@selector(hexShowAddressWidthDialog:) keyEquivalent:@""];
    addrItem.target = self;
    NSMenuItem *colsItem = [menu addItemWithTitle:L(@"menu.context.columns") action:@selector(hexShowColumnsDialog:) keyEquivalent:@""];
    colsItem.target = self;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *zoomInItem = [menu addItemWithTitle:L(@"menu.context.zoomIn") action:@selector(hexZoomIn:) keyEquivalent:@""];
    zoomInItem.target = self;
    NSMenuItem *zoomOutItem = [menu addItemWithTitle:L(@"menu.context.zoomOut") action:@selector(hexZoomOut:) keyEquivalent:@""];
    zoomOutItem.target = self;
    NSMenuItem *zoomResetItem = [menu addItemWithTitle:L(@"menu.context.zoomReset") action:@selector(hexZoomReset:) keyEquivalent:@""];
    zoomResetItem.target = self;
    return menu;
}

- (void)undo:(id)sender
{
    performScintillaUndoRedo(SCI_UNDO);
}

- (void)redo:(id)sender
{
    performScintillaUndoRedo(SCI_REDO);
}

- (void)cut:(id)sender
{
    cutHexSelection();
}

- (void)copy:(id)sender
{
    copyHexSelectionToPasteboard();
}

- (void)paste:(id)sender
{
    pasteBytesFromPasteboard();
}

- (void)delete:(id)sender
{
    deleteHexSelection();
}

- (void)selectAll:(id)sender
{
    selectAllHexBytes();
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL action = item.action;
    if (action == @selector(undo:)) {
        return canPerformScintillaUndoRedo(SCI_CANUNDO);
    }
    if (action == @selector(redo:)) {
        return canPerformScintillaUndoRedo(SCI_CANREDO);
    }
    if (action == @selector(cut:) || action == @selector(copy:) || action == @selector(delete:) ||
        action == @selector(hexCut:) || action == @selector(hexCopy:) || action == @selector(hexDelete:) ||
        action == @selector(hexCutBinary:) || action == @selector(hexCopyBinary:)) {
        // Only enable when there is an actual selection (linear range or rect).
        // Previously this also returned YES whenever the cursor sat on any byte
        // inside the buffer — selectedOrCurrentRange falls back to a 1-byte
        // range at the cursor when no real selection exists — which made
        // Cut/Copy permanently enabled and surprised users into thinking the
        // commands had no useful no-op state.
        return hasByteSelection() || hasRectSelection();
    }
    if (action == @selector(paste:) || action == @selector(hexPaste:) || action == @selector(hexPasteBinary:)) {
        // First: do we own a fresh in-process snapshot? That's authoritative
        // — the bytes are right there in HexClipboardOwner._bytes — and works
        // regardless of whether AppKit decides to materialize the promised
        // pasteboard types for a validation read. Without this short-circuit,
        // calling dataForType: against our own promised public.data during
        // menu validation returned nil on macOS 26 (the promise isn't
        // materialized until an actual paste-action read), so Paste appeared
        // disabled immediately after our own Cmd-C — and a subsequent
        // keyboard Cmd-V went through performKeyEquivalent but pasteboard
        // reads still came back empty, so the paste silently no-op'd.
        if (currentlyOwnedHexSnapshot() != nil) {
            return YES;
        }
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        return [pasteboard dataForType:NSPasteboardTypeString] != nil ||
            [pasteboard dataForType:@"public.data"] != nil ||
            [pasteboard dataForType:kHexRectPasteboardType] != nil ||
            [pasteboard stringForType:NSPasteboardTypeString] != nil;
    }
    if (action == @selector(selectAll:)) {
        return !hexBufferEmpty();
    }
    return YES;
}

- (void)hexCut:(id)sender
{
    cutHexSelection();
}

- (void)hexCopy:(id)sender
{
    copyHexSelectionToPasteboard();
}

- (void)hexPaste:(id)sender
{
    pasteBytesFromPasteboard();
}

- (void)hexDelete:(id)sender
{
    deleteHexSelection();
}

- (void)hexCutBinary:(id)sender
{
    cutHexSelectionBinary();
}

- (void)hexCopyBinary:(id)sender
{
    copyHexSelectionAsBinary();
}

- (void)hexPasteBinary:(id)sender
{
    pasteBinaryFromPasteboard();
}

- (void)hexZoomIn:(id)sender
{
    zoomHexFont(1);
}

- (void)hexZoomOut:(id)sender
{
    zoomHexFont(-1);
}

- (void)hexZoomReset:(id)sender
{
    resetHexFontZoom();
}

- (void)hexViewSet8Bit:(id)sender    { setHexViewBytesPerCell(1); }
- (void)hexViewSet16Bit:(id)sender   { setHexViewBytesPerCell(2); }
- (void)hexViewSet32Bit:(id)sender   { setHexViewBytesPerCell(4); }
- (void)hexViewSet64Bit:(id)sender   { setHexViewBytesPerCell(8); }
- (void)hexViewToggleBinary:(id)sender { toggleHexViewBinary(); }
- (void)hexViewToggleEndian:(id)sender { toggleHexViewEndian(); }

- (void)hexShowAddressWidthDialog:(id)sender
{
    const int value = promptHexInteger(
        L(@"addressWidth.title"),
        [NSString stringWithFormat:L(@"addressWidth.message"),
            HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH],
        g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
    if (value == -1) {
        return;
    }
    if (value == -2) {
        presentHexValidationError([NSString stringWithFormat:L(@"addressWidth.invalidRange"),
            HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH]);
        return;
    }
    setHexAddressWidth(value);
}

- (void)hexShowColumnsDialog:(id)sender
{
    const int limit = columnsLimitForBytesPerCell(g_bytesPerCell);
    const int value = promptHexInteger(
        L(@"columns.title"),
        [NSString stringWithFormat:L(@"columns.message"), limit],
        g_columns, 1, limit);
    if (value == -1) {
        return;
    }
    if (value == -2) {
        presentHexValidationError([NSString stringWithFormat:L(@"columns.invalidMaximum"),
            HEX_MAX_BYTES_PER_ROW]);
        return;
    }
    setHexColumns(value);
}

- (void)hexShowGotoDialog:(id)sender
{
    presentHexGotoDialog();
}

- (void)hexShowFindDialog:(id)sender
{
    presentHexFindDialog(NO);
}

- (void)hexShowFindReplaceDialog:(id)sender
{
    presentHexFindDialog(YES);
}

- (void)hexFindNext:(id)sender
{
    NSString *err = nil;
    if (!executeHexFindNext(hexedit::SearchDirection::Forward, &err)) {
        presentHexValidationError(err ?: L(@"find.errorNotFound"));
    }
}

- (void)hexFindPrevious:(id)sender
{
    NSString *err = nil;
    if (!executeHexFindNext(hexedit::SearchDirection::Backward, &err)) {
        presentHexValidationError(err ?: L(@"find.errorNotFound"));
    }
}

- (BOOL)byteOffsetAtPoint:(NSPoint)point offset:(size_t *)offset nibble:(NSInteger *)nibble field:(HexCursorField *)field
{
    const NSInteger row = [self rowAtPoint:point];
    const NSInteger column = [self columnAtPoint:point];
    if (row < 0 || column < 0) {
        return NO;
    }

    NSTableColumn *tableColumn = self.tableColumns[column];
    NSString *identifier = tableColumn.identifier;
    const NSInteger cellIndex = cellColumnIndex(identifier);
    if (cellIndex >= 0) {
        const hexedit::ViewMode mode = currentViewMode();
        NSFont *font = hexTableFont();
        const CGFloat glyphWidth = monospacedGlyphWidth(font);
        const CGFloat glyphStart = cellGlyphLeft(self, column, row, font);
        const int totalDigits = std::max(hexedit::digitsPerCell(mode), 1);
        int digitInCell = static_cast<int>(std::floor((point.x - glyphStart) / glyphWidth));
        digitInCell = std::clamp(digitInCell, 0, totalDigits - 1);
        const hexedit::PhysicalPosition phys =
            hexedit::physicalPositionForDisplay(static_cast<std::size_t>(cellIndex), digitInCell, mode);
        const size_t byteOffset = static_cast<size_t>(row) * static_cast<size_t>(currentBytesPerRow()) + phys.byteInRow;
        if (!isVisibleEditableOffset(byteOffset)) {
            return NO;
        }
        if (offset) {
            *offset = byteOffset;
        }
        if (nibble) {
            // phys.subInByte is the nibble (0-1) in hex mode or the bit index (0-7,
            // MSB-first) in binary mode. The cursor field accepts either range — bit
            // edits use it directly via planBitEdit.
            *nibble = static_cast<NSInteger>(phys.subInByte);
        }
        if (field) {
            *field = HexCursorField::Hex;
        }
        return YES;
    }

    if ([identifier isEqualToString:@"ascii"]) {
        NSRect cellFrame = [self frameOfCellAtColumn:column row:row];
        NSFont *font = hexTableFont();
        CGFloat charWidth = monospacedGlyphWidth(font);
        const NSInteger bpr = static_cast<NSInteger>(currentBytesPerRow());
        NSInteger asciiIndex = std::clamp<NSInteger>(static_cast<NSInteger>((point.x - asciiGlyphLeft(self, column, row)) / charWidth), 0, bpr - 1);
        const size_t byteOffset = static_cast<size_t>(row) * static_cast<size_t>(bpr) + static_cast<size_t>(asciiIndex);
        if (!isVisibleEditableOffset(byteOffset)) {
            return NO;
        }

        if (offset) {
            *offset = byteOffset;
        }
        if (nibble) {
            *nibble = 0;
        }
        if (field) {
            *field = HexCursorField::Ascii;
        }
        return YES;
    }

    return NO;
}

- (void)updateByteSelectionToOffset:(size_t)byteOffset field:(HexCursorField)field
{
    selectedByteStart = std::min(selectionAnchorByte, byteOffset);
    selectedByteEnd = std::max(selectionAnchorByte, byteOffset) + 1;
    activeCursorField = field;
    // Caret follows the mouse cursor: forward drag (byteOffset >= anchor)
    // ⇒ caret at selectedByteEnd (one past the rightmost byte, the
    // existing end-of-selection convention; the during-drag flush in
    // drawRect: visually plants it on the right edge of byte
    // selectedByteEnd-1). Backward drag (byteOffset < anchor) ⇒ caret
    // at selectedByteStart (= byteOffset, the byte the user is currently
    // hovering over), which renders at that byte's left edge — visually
    // before the first selected byte. Matches the rect-mode convention
    // where the caret tracks the dragged-to corner regardless of which
    // side of the anchor the user is on.
    activeByteOffset = (byteOffset >= selectionAnchorByte) ? selectedByteEnd : selectedByteStart;
    activeHexNibble = 0;
    clampActiveCursor();
    [self setNeedsDisplay:YES];
}

// Modifier-mask comparison helper. We accept either Option-drag or
// Shift+Option-drag for rectangular selection — both are NPP conventions and
// users come from either muscle-memory background. Cmd or Ctrl in the mix
// means "something else" and disqualifies. Caps Lock and other irrelevant
// flags are filtered out by masking down to the four meaningful bits.
- (BOOL)hexEventStartsRectDrag:(NSEvent *)event
{
    const NSEventModifierFlags relevant = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    return relevant == NSEventModifierFlagOption ||
           relevant == (NSEventModifierFlagOption | NSEventModifierFlagShift);
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint scrollOrigin = [self currentScrollOrigin];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = [self rowAtPoint:point];
    const NSInteger column = [self columnAtPoint:point];

    const BOOL isRectModifier = [self hexEventStartsRectDrag:event];

    if (row >= 0 && column >= 0) {
        NSTableColumn *tableColumn = self.tableColumns[column];
        NSString *identifier = tableColumn.identifier;

        if ([identifier isEqualToString:@"offset"]) {
            // Address column: not selectable. Click (with or without modifiers) toggles
            // a bookmark on the row.
            toggleBookmarkRow(static_cast<size_t>(row));
            [self setNeedsDisplayInRect:[self rectOfRow:row]];
            return;
        }

        size_t byteOffset = 0;
        NSInteger nibble = 0;
        HexCursorField field = HexCursorField::Hex;
        if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field]) {
            if (isRectModifier) {
                // Byte-pane or ASCII-pane rect drag — cell granular.
                clearAllByteSelections();
                g_rectAnchorOffset = byteOffset;
                g_rectOriginField = field;
                g_isSelectingRect = true;
                updateRectSelectionToOffset(byteOffset);
                [self.window makeFirstResponder:self];
                [self reloadDataPreservingScrollOrigin:scrollOrigin];
                return;
            }
            clearAllByteSelections();
            selectionAnchorByte = byteOffset;
            isSelectingBytes = true;
            if (field == HexCursorField::Hex) {
                setActiveHexCursor(byteOffset, nibble);
            } else {
                setActiveAsciiCursor(byteOffset);
            }
            [self.window makeFirstResponder:self];
            [self reloadDataPreservingScrollOrigin:scrollOrigin];
            return;
        }
    }

    [super mouseDown:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (g_isSelectingRect) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        const NSInteger row = [self rowAtPoint:point];

        size_t byteOffset = 0;
        NSInteger nibble = 0;
        HexCursorField field = g_rectOriginField;
        if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field]) {
            updateRectSelectionToOffset(byteOffset);
        } else if (row >= 0) {
            // Pointer is past the right edge of the byte / ASCII panes — clamp to the
            // row's last byte so the rect extends across the full visible row width.
            const size_t bpr = static_cast<size_t>(currentBytesPerRow());
            const size_t rowEnd = static_cast<size_t>(row) * bpr + (bpr - 1);
            updateRectSelectionToOffset(std::min(rowEnd,
                previewTotalLength > 0 ? previewTotalLength - 1 : static_cast<size_t>(0)));
        }
        return;
    }

    if (!isSelectingBytes) {
        [super mouseDragged:event];
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    size_t byteOffset = 0;
    NSInteger nibble = 0;
    HexCursorField field = activeCursorField;
    if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field]) {
        [self updateByteSelectionToOffset:byteOffset field:field];
    }
}

- (void)mouseUp:(NSEvent *)event
{
    // Drag finished. For rect drags where the active corner sits on the
    // rect's right column, advance activeByteOffset by one byte so the
    // post-drag caret renders at the *next* byte's left edge instead of
    // staying on the dragged-to byte's right edge. Mirror the linear
    // convention ("after a drag, the cursor is at the start of the next
    // byte"). The during-drag right-edge shift in drawRect: only fires
    // while activeByteOffset's column equals rectColEnd, so advancing
    // past that turns it off automatically — no extra render-side flag
    // needed.
    if (g_isSelectingRect && g_rectActive && previewTotalLength > 0) {
        const size_t bpr = static_cast<size_t>(currentBytesPerRow());
        if (bpr > 0) {
            const size_t rectColStart = g_rectSelection.originOffset % bpr;
            const size_t rectColEnd = rectColStart + g_rectSelection.width - 1;
            const size_t activeCol = activeByteOffset % bpr;
            if (activeCol == rectColEnd && rectColEnd > rectColStart) {
                const size_t advanced = activeByteOffset + 1;
                // Stay on the rect's row (don't wrap into the next row);
                // bpr > 0 above guards the modulo.
                if ((advanced / bpr) == (activeByteOffset / bpr)) {
                    activeByteOffset = advanced;
                    [self setNeedsDisplay:YES];
                }
            }
        }
    }
    isSelectingBytes = false;
    g_isSelectingRect = false;
    [super mouseUp:event];
}

- (void)keyDown:(NSEvent *)event
{
    NSPoint scrollOrigin = [self currentScrollOrigin];
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar character = [characters characterAtIndex:0];
    const NSEventModifierFlags modifiers = event.modifierFlags;
    const NSEventModifierFlags commandOrControl = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl);
    if (commandOrControl != 0) {
        // Cmd+Home / Cmd+End jump to document start/end. This mirrors the Notepad++
        // Windows shortcut and lets editing reach EOF on documents larger than one row.
        if ((modifiers & NSEventModifierFlagCommand) != 0) {
            if (character == NSHomeFunctionKey) {
                clearByteSelection();
                writeBackCursor(hexedit::cursorToDocumentStart(currentCursor()));
                [self reloadDataPreservingScrollOrigin:scrollOrigin];
                return;
            }
            if (character == NSEndFunctionKey) {
                clearByteSelection();
                writeBackCursor(hexedit::cursorToDocumentEnd(currentCursor(), currentDocumentView()));
                [self reloadDataPreservingScrollOrigin:scrollOrigin];
                return;
            }
            // Cmd+L → Go to Offset (matches the macOS browser/Pages convention for jump-to-location).
            // The Notepad++ host's IDM_SEARCH_GOTOLINE plumbing isn't intercepted yet on macOS,
            // so this keybinding is the only way to trigger Goto without right-clicking.
            if (character == 'l' || character == 'L') {
                presentHexGotoDialog();
                return;
            }
            // Cmd+F → Find (Cmd+Alt+F → Find and Replace), Cmd+G → Find Next, Cmd+Shift+G → Find Prev.
            // Mirrors the Windows Find/Replace plugin entry point (IDM_SEARCH_FIND wired in
            // Hex.cpp) using macOS conventions for the keybindings.
            if (character == 'f' || character == 'F') {
                presentHexFindDialog((modifiers & NSEventModifierFlagOption) != 0);
                return;
            }
            if (character == 'g' || character == 'G') {
                NSString *err = nil;
                const hexedit::SearchDirection dir = ((modifiers & NSEventModifierFlagShift) != 0)
                    ? hexedit::SearchDirection::Backward
                    : hexedit::SearchDirection::Forward;
                if (!executeHexFindNext(dir, &err)) {
                    presentHexValidationError(err ?: L(@"find.errorNotFound"));
                }
                return;
            }
        }
        [super keyDown:event];
        return;
    }

    if (activeCursorField == HexCursorField::Ascii && handleAsciiAltNumpadDigit(event)) {
        redrawHexRowsPreservingScroll(activeByteOffset, activeByteOffset, scrollOrigin);
        return;
    }

    // Shift+<rect-modifier>+arrow grows or shrinks a rectangular selection. If no rect
    // is active, this starts one anchored at the current caret. The "current" corner —
    // tracked by activeByteOffset — moves by one byte (Left/Right) or one row (Up/Down)
    // and the rect is rebuilt around the unchanged anchor. Right at the end of a row
    // and Left at the start of a row are clamped so column-edge arrow presses don't
    // accidentally jump rows and corrupt the rectangle's geometry.
    // Keyboard rect extend: Shift+Option+arrow grows the active rect from
    // its anchor. Same modifier combo regardless of whether the rect was
    // initiated with Option-drag or Shift+Option-drag (both are accepted
    // for the start; this is the canonical extend gesture).
    const NSEventModifierFlags rectExtendFlags = NSEventModifierFlagShift | NSEventModifierFlagOption;
    const NSEventModifierFlags relevantMods = modifiers &
        (NSEventModifierFlagShift | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    const bool isRectExtend = (relevantMods == rectExtendFlags) &&
        (character == NSLeftArrowFunctionKey || character == NSRightArrowFunctionKey ||
         character == NSUpArrowFunctionKey || character == NSDownArrowFunctionKey);
    if (isRectExtend && previewTotalLength > 0) {
        const size_t bpr = static_cast<size_t>(currentBytesPerRow());
        if (!hasRectSelection()) {
            // Bootstrap a 1×1 rect at the caret on first extension.
            clearByteSelection();
            g_rectAnchorOffset = activeByteOffset;
            g_rectOriginField = activeCursorField;
            updateRectSelectionToOffset(activeByteOffset);
        }
        const size_t rowStart = (activeByteOffset / bpr) * bpr;
        const size_t rowEnd = std::min(rowStart + bpr, previewTotalLength);
        size_t target = activeByteOffset;
        switch (character) {
        case NSLeftArrowFunctionKey:
            if (target > rowStart) target -= 1;
            break;
        case NSRightArrowFunctionKey:
            if (target + 1 < rowEnd) target += 1;
            break;
        case NSUpArrowFunctionKey:
            if (target >= bpr) target -= bpr;
            break;
        case NSDownArrowFunctionKey:
            if (target + bpr < previewTotalLength) target += bpr;
            else if (previewTotalLength > 0) target = previewTotalLength - 1;
            break;
        }
        updateRectSelectionToOffset(target);
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    }

    switch (character) {
    case NSBackspaceCharacter:
    case NSLeftArrowFunctionKey:
        clearAllByteSelections();
        writeBackCursor(hexedit::navigateLeft(currentCursor(), currentDocumentView(),
                                               currentViewMode(), currentBytesPerRow()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSRightArrowFunctionKey:
        clearAllByteSelections();
        writeBackCursor(hexedit::navigateRight(currentCursor(), currentDocumentView(),
                                                currentViewMode(), currentBytesPerRow()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSUpArrowFunctionKey:
        clearAllByteSelections();
        moveActiveCursor(-16);
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSDownArrowFunctionKey:
        clearAllByteSelections();
        moveActiveCursor(16);
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSHomeFunctionKey:
        clearAllByteSelections();
        writeBackCursor(hexedit::cursorToLineStart(currentCursor()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSEndFunctionKey:
        clearAllByteSelections();
        writeBackCursor(hexedit::cursorToLineEnd(currentCursor(), currentDocumentView()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    default:
        break;
    }

    // A typed character with an active rect: clear the rect (visual signal that we're
    // switching back to keyboard editing) and apply the edit at the cursor as usual.
    // Rectangular replacement of the rect's bytes is intentionally limited to Delete
    // (zero-fill, chunk 4) and Pattern Replace — typing a single byte across a 2D rect
    // has no obvious meaning, so the safest UX is to dismiss and let the type land at
    // the caret.
    if (hasRectSelection()) {
        clearRectSelection();
        [self setNeedsDisplay:YES];
    }

    const bool selectionWasActive = hasByteSelection();
    const size_t editedOffset = selectionWasActive ? selectedByteStart : activeByteOffset;
    bool handled = false;
    if (activeCursorField == HexCursorField::Hex) {
        // In binary notation, only '0' and '1' are valid digit input — they edit a single
        // bit. Hex notation accepts 0-9 / a-f / A-F via planHexDigitEdit.
        if (g_notation == hexedit::CellNotation::Binary) {
            handled = handleBinaryDigit(character);
        } else {
            handled = handleHexDigit(character);
        }
    } else {
        handled = handleAsciiCharacter(character);
    }

    if (handled) {
        if (selectionWasActive) {
            redrawHexTablePreservingScroll(scrollOrigin);
        } else {
            redrawHexRowsPreservingScroll(editedOffset, activeByteOffset, scrollOrigin);
        }
        return;
    }

    [super keyDown:event];
}

- (void)flagsChanged:(NSEvent *)event
{
    if ((event.modifierFlags & NSEventModifierFlagOption) == 0 && asciiAltNumpadValue >= 0) {
        NSPoint scrollOrigin = [self currentScrollOrigin];
        const size_t editedOffset = activeByteOffset;
        if (commitAsciiAltNumpadEntry()) {
            redrawHexRowsPreservingScroll(editedOffset, activeByteOffset, scrollOrigin);
            return;
        }
    }

    [super flagsChanged:event];
}
@end

static void showHexPreview();
static void toggleHexPreview();
static void hideHexPreview();
static void showAbout();
static NSFont *hexTableFont();
static CGFloat preciseTextWidth(NSString *text, NSFont *font);
static CGFloat textWidth(NSString *text, NSFont *font);
static NSFont *hexTableFont()
{
    // Base size: the user's explicit Font tab choice (g_fontSize). The
    // Cmd+/Cmd− zoom delta still adds on top so that existing zoom
    // muscle memory keeps working — pinch and ⌘+/− move proportionally
    // around whatever size the dialog set.
    const CGFloat baseSize = (g_fontSize > 0) ? static_cast<CGFloat>(g_fontSize) : editorBaseFontSize;
    const CGFloat fontSize = std::clamp(baseSize + static_cast<CGFloat>(hexFontZoomDelta),
                                          HEX_MIN_FONT_SIZE, HEX_MAX_FONT_SIZE);

    // Family: g_fontName, falling back to the system monospaced font if the
    // requested family isn't installed (renamed, deleted, or system ships
    // a different default). This is the safety net behind the popup's
    // fixed-pitch filter — even if the popup shipped a name we couldn't
    // resolve, rendering still has SOMETHING monospaced to draw with.
    NSFont *base = nil;
    if (g_fontName.length > 0) {
        base = [NSFont fontWithName:g_fontName size:fontSize];
    }
    if (base == nil) {
        base = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
    }

    // Traits: bold / italic via NSFontDescriptor's symbolic-traits API.
    // One descriptor call applies both bits at once. If the family doesn't
    // have a bold or italic face installed (some monospaced display fonts
    // omit one or the other), `fontWithDescriptor:` returns nil and we
    // keep the untraited base so the user at least sees their family.
    NSFontDescriptorSymbolicTraits traits = 0;
    if (g_fontBold)   traits |= NSFontDescriptorTraitBold;
    if (g_fontItalic) traits |= NSFontDescriptorTraitItalic;
    if (traits != 0) {
        NSFontDescriptor *traited = [base.fontDescriptor fontDescriptorWithSymbolicTraits:traits];
        NSFont *withTraits = [NSFont fontWithDescriptor:traited size:fontSize];
        if (withTraits != nil) base = withTraits;
    }
    return base;
}

static CGFloat preciseTextWidth(NSString *text, NSFont *font)
{
    NSDictionary *attributes = @{ NSFontAttributeName: font };
    return [text sizeWithAttributes:attributes].width;
}

static CGFloat textWidth(NSString *text, NSFont *font)
{
    return ceil(preciseTextWidth(text, font));
}

static CGFloat monospacedGlyphWidth(NSFont *font)
{
    return std::max<CGFloat>(preciseTextWidth(@"0000000000000000", font) / 16.0, 1.0);
}

static NSRect textDrawingRect(NSTableView *tableView, NSInteger column, NSInteger row)
{
    NSRect cellFrame = [tableView frameOfCellAtColumn:column row:row];
    NSTableColumn *tableColumn = tableView.tableColumns[column];
    id cell = tableColumn.dataCell;
    if ([cell respondsToSelector:@selector(drawingRectForBounds:)]) {
        return [cell drawingRectForBounds:cellFrame];
    }

    return cellFrame;
}

static CGFloat asciiGlyphLeft(NSTableView *tableView, NSInteger column, NSInteger row)
{
    return NSMinX(textDrawingRect(tableView, column, row));
}

// Factory-default colours for the Colors tab. Hard-coded sRGB values for two
// modes: Light is the upstream Windows HexEditor plugin's palette verbatim
// (see macos/design/options-dialog-reference.md); Dark is a parallel set
// chosen to keep equivalent visual semantics against a dark background.
// Each factory function picks at call time based on NSApp.effectiveAppearance,
// so live rendering tracks Light/Dark switches automatically. The dialog's
// Reset path snapshots whichever set is current when the user clicks Reset
// (and Apply commits the snapshot — re-Reset in the other mode if needed).
//
// Why hard-coded rather than NSColor.labelColor / textBackgroundColor:
// dynamic NSColors resolve based on whatever effective appearance is in
// scope when the conversion runs, which is unstable across the dialog ↔
// hex-view boundary and produced a white-on-white commit at one point.
// Hard-coded values are predictable in every appearance context.

static BOOL hexEffectiveAppearanceIsDark()
{
    NSAppearanceName best = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua,
    ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua];
}

// Light = Windows HexEditor defaults, taken verbatim from
// HexEditor/src/Hex.cpp:412-420 (the upstream `prop.colorProp.rgb*` ini
// fallbacks). Earlier values used the design-doc approximations
// (#B0B5FF / #FFA0A0 / #E0E0E0) which differed from the actual Windows
// initialisers (#8888FF / #FF8888 / #DFDFDF) by enough that the dialog's
// Reset-to-Defaults didn't visually match the Windows reference.
static NSColor *hexFactoryRegularTextFgLight() { return [NSColor colorWithSRGBRed:0.0       green:0.0       blue:0.0       alpha:1.0]; } // #000000
static NSColor *hexFactoryRegularTextBgLight() { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactorySelectionFgLight()   { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactorySelectionBgLight()   { return [NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0xFF/255.0 alpha:1.0]; } // #8888FF
static NSColor *hexFactoryCompareFgLight()     { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactoryCompareBgLight()     { return [NSColor colorWithSRGBRed:1.0       green:0x88/255.0 blue:0x88/255.0 alpha:1.0]; } // #FF8888
static NSColor *hexFactoryBookmarkFgLight()    { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactoryBookmarkBgLight()    { return [NSColor colorWithSRGBRed:1.0       green:0.0       blue:0.0       alpha:1.0]; } // #FF0000
static NSColor *hexFactoryCurrentLineBgLight() { return [NSColor colorWithSRGBRed:0xDF/255.0 green:0xDF/255.0 blue:0xDF/255.0 alpha:1.0]; } // #DFDFDF

// Dark = parallel set keeping equivalent visual semantics against a dark
// background. Bookmark red is shared with Light because pure red has good
// contrast in both modes; everything else is a darker / lower-saturation
// analogue so highlights remain readable on a near-black canvas.
static NSColor *hexFactoryRegularTextFgDark() { return [NSColor colorWithSRGBRed:0xEB/255.0 green:0xEB/255.0 blue:0xEB/255.0 alpha:1.0]; } // #EBEBEB
static NSColor *hexFactoryRegularTextBgDark() { return [NSColor colorWithSRGBRed:0x1E/255.0 green:0x1E/255.0 blue:0x1E/255.0 alpha:1.0]; } // #1E1E1E
static NSColor *hexFactorySelectionFgDark()   { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactorySelectionBgDark()   { return [NSColor colorWithSRGBRed:0x48/255.0 green:0x58/255.0 blue:0xE0/255.0 alpha:1.0]; } // #4858E0 — keeps Windows 240° hue at higher saturation so the highlight reads as blue against #1E1E1E rather than as another dark patch
static NSColor *hexFactoryCompareFgDark()     { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactoryCompareBgDark()     { return [NSColor colorWithSRGBRed:0x80/255.0 green:0x30/255.0 blue:0x30/255.0 alpha:1.0]; } // #803030
static NSColor *hexFactoryBookmarkFgDark()    { return [NSColor colorWithSRGBRed:1.0       green:1.0       blue:1.0       alpha:1.0]; } // #FFFFFF
static NSColor *hexFactoryBookmarkBgDark()    { return [NSColor colorWithSRGBRed:1.0       green:0.0       blue:0.0       alpha:1.0]; } // #FF0000 (shared)
static NSColor *hexFactoryCurrentLineBgDark() { return [NSColor colorWithSRGBRed:0x4D/255.0 green:0x4D/255.0 blue:0x4D/255.0 alpha:1.0]; } // #4D4D4D — bumped from #3F3F3F (and originally #2D2D2D) so the gap above text bg #1E1E1E is wide enough to clearly read as a row highlight

static NSColor *hexFactoryRegularTextFg()  { return hexEffectiveAppearanceIsDark() ? hexFactoryRegularTextFgDark()  : hexFactoryRegularTextFgLight();  }
static NSColor *hexFactoryRegularTextBg()  { return hexEffectiveAppearanceIsDark() ? hexFactoryRegularTextBgDark()  : hexFactoryRegularTextBgLight();  }
static NSColor *hexFactorySelectionFg()    { return hexEffectiveAppearanceIsDark() ? hexFactorySelectionFgDark()    : hexFactorySelectionFgLight();    }
static NSColor *hexFactorySelectionBg()    { return hexEffectiveAppearanceIsDark() ? hexFactorySelectionBgDark()    : hexFactorySelectionBgLight();    }
static NSColor *hexFactoryCompareFg()      { return hexEffectiveAppearanceIsDark() ? hexFactoryCompareFgDark()      : hexFactoryCompareFgLight();      }
static NSColor *hexFactoryCompareBg()      { return hexEffectiveAppearanceIsDark() ? hexFactoryCompareBgDark()      : hexFactoryCompareBgLight();      }
static NSColor *hexFactoryBookmarkFg()     { return hexEffectiveAppearanceIsDark() ? hexFactoryBookmarkFgDark()     : hexFactoryBookmarkFgLight();     }
static NSColor *hexFactoryBookmarkBg()     { return hexEffectiveAppearanceIsDark() ? hexFactoryBookmarkBgDark()     : hexFactoryBookmarkBgLight();     }
static NSColor *hexFactoryCurrentLineBg()  { return hexEffectiveAppearanceIsDark() ? hexFactoryCurrentLineBgDark()  : hexFactoryCurrentLineBgLight();  }

// Each helper consults the matching mode-specific override first; nil
// falls back to the factory default for the current mode. Live rendering
// re-evaluates on every paint, so the right mode's value is always used
// (no need to refresh anything when NppThemeManager flips Light↔Dark —
// the next draw picks up the new mode automatically). The helpers
// alongside (`hexFactory*()`) also branch on appearance, so once the
// override is nil the factory does the mode switch internally.

static NSColor *hexRegularTextColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorRegularTextFgDark : g_colorRegularTextFgLight;
    return override ?: hexFactoryRegularTextFg();
}

static NSColor *hexRegularTextBackgroundColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorRegularTextBgDark : g_colorRegularTextBgLight;
    return override ?: hexFactoryRegularTextBg();
}

static NSColor *hexSelectionTextColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorSelectionFgDark : g_colorSelectionFgLight;
    return override ?: hexFactorySelectionFg();
}

static NSColor *hexSelectionColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorSelectionBgDark : g_colorSelectionBgLight;
    return override ?: hexFactorySelectionBg();
}

static NSColor *hexCurrentLineSelectionColor()
{
    // Lighter wash for "selected and on the current line" — the selection
    // colour at reduced alpha so the row highlight underneath stays
    // discernible.
    return [hexSelectionColor() colorWithAlphaComponent:0.6];
}

static NSColor *hexCurrentLineColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorCurrentLineBgDark : g_colorCurrentLineBgLight;
    return override ?: hexFactoryCurrentLineBg();
}

static NSColor *hexCompareDiffColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorCompareBgDark : g_colorCompareBgLight;
    return override ?: hexFactoryCompareBg();
}

static NSColor *hexCompareDiffTextColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorCompareFgDark : g_colorCompareFgLight;
    return override ?: hexFactoryCompareFg();
}

static NSColor *hexBookmarkBackgroundColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorBookmarkBgDark : g_colorBookmarkBgLight;
    return override ?: hexFactoryBookmarkBg();
}

static NSColor *hexBookmarkTextColor()
{
    NSColor *override = hexEffectiveAppearanceIsDark() ? g_colorBookmarkFgDark : g_colorBookmarkFgLight;
    return override ?: hexFactoryBookmarkFg();
}

static CGFloat paddedTextWidth(NSString *text, NSFont *font)
{
    return textWidth(text, font) +
        ceil(monospacedGlyphWidth(font) * HEX_CELL_HORIZONTAL_PADDING_GLYPHS);
}

// Width an NSTableHeaderCell needs to render `title` without ellipsizing — text in
// the header font plus the cell's own internal insets. Using NSTableHeaderCell.cellSize
// (rather than a hand-picked padding constant) means the column is exactly as wide as
// macOS's own header rendering needs, no more.
static CGFloat headerCellNaturalWidth(NSString *title)
{
    static NSTableHeaderCell *probe = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        probe = [[NSTableHeaderCell alloc] init];
    });
    probe.stringValue = title;
    return ceil([probe cellSize].width);
}

// Widest cell-column header across all 256 possible "%02zx" indices ("00".."ff").
// Per-glyph metrics make "00" the widest in some fonts, "04" or "ee" in others —
// measure them all and take the real max so the cell width is right for every
// rendered title regardless of font / locale / bytesPerRow.
static CGFloat widestHexHeaderWidth()
{
    CGFloat maxWidth = 0.0;
    for (int i = 0; i < 256; ++i) {
        NSString *candidate = [NSString stringWithFormat:@"%02x", i];
        maxWidth = std::max(maxWidth, headerCellNaturalWidth(candidate));
    }
    return maxWidth;
}

// Width of the spacer column between the address pane and the first hex byte.
// A real column (rather than padding inside the offset column) gives the address
// pane a visible frame-edge gap from the hex grid. Glyph-width-relative so the
// gap stays proportional under pinch-zoom.
static CGFloat offsetTrailingPadding(NSFont *font)
{
    return ceil(monospacedGlyphWidth(font) * HEX_OFFSET_TRAILING_GLYPHS);
}

// Width of the spacer column between the last hex cell and the ASCII pane.
// Glyph-width-relative for the same scaling reason.
static CGFloat asciiSeparatorWidth(NSFont *font)
{
    return ceil(monospacedGlyphWidth(font) * HEX_ASCII_SEPARATOR_GLYPHS);
}

static CGFloat offsetColumnWidth(NSFont *font)
{
    const int width = std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(width) withString:@"0" startingAtIndex:0];
    return std::max(paddedTextWidth(sample, font), headerCellNaturalWidth(L(@"table.header.offset")));
}

static CGFloat cellColumnWidth(NSFont *font, const hexedit::ViewMode &mode)
{
    const int digits = hexedit::digitsPerCell(mode);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(std::max(digits, 1))
                                          withString:@"0"
                                     startingAtIndex:0];
    return std::max({paddedTextWidth(sample, font),
                     paddedTextWidth(@"0F", font),
                     widestHexHeaderWidth()});
}

static CGFloat cellGlyphLeft(NSTableView *tableView, NSInteger column, NSInteger row, NSFont *font)
{
    NSRect drawingRect = textDrawingRect(tableView, column, row);
    const int digits = std::max(currentDigitsPerCell(), 1);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(digits) withString:@"0" startingAtIndex:0];
    const CGFloat textPx = preciseTextWidth(sample, font);
    return NSMinX(drawingRect) + std::max<CGFloat>((NSWidth(drawingRect) - textPx) / 2.0, 0.0);
}

static CGFloat asciiColumnWidth(NSFont *font)
{
    const int bpr = std::max(currentBytesPerRow(), 1);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(bpr) withString:@"." startingAtIndex:0];
    return std::max(paddedTextWidth(sample, font), headerCellNaturalWidth(L(@"table.header.ascii")));
}

static CGFloat tableContentWidth(NSFont *font)
{
    const hexedit::ViewMode mode = currentViewMode();
    const int cells = std::max(currentCellsPerRow(), 1);
    return offsetColumnWidth(font) + offsetTrailingPadding(font) + (static_cast<CGFloat>(cells) * cellColumnWidth(font, mode)) + asciiSeparatorWidth(font) + asciiColumnWidth(font);
}

static CGFloat tableContainerWidth(NSFont *font)
{
    return tableContentWidth(font) + 10.0;
}

static NppHandle getCurrentScintilla()
{
    int currentView = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, reinterpret_cast<intptr_t>(&currentView));

    if (currentView == MAIN_VIEW) {
        return nppData._scintillaMainHandle;
    }

    if (currentView == SUB_VIEW) {
        return nppData._scintillaSecondHandle;
    }

    return 0;
}

static uintptr_t getCurrentBufferId()
{
    return static_cast<uintptr_t>(nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTBUFFERID, 0, 0));
}

// Returns the absolute path of the buffer with the given ID, or nil if NPP
// can't resolve one (e.g. the buffer is an untitled new document with no
// on-disk file). NPP-Mac fills the lParam buffer as UTF-8 narrow chars
// (NppPluginManager.mm: strlcpy(buf, ed.filePath.UTF8String, 1024)); the
// upstream Windows API uses wide chars. Don't get this wrong — reading a
// UTF-8 byte stream as unichar gives garbage that never matches anything.
static NSString *getFullPathFromBufferId(uintptr_t bufferId)
{
    if (bufferId == 0) return nil;
    constexpr size_t kMaxPath = 4096;
    NSMutableData *out = [NSMutableData dataWithLength:kMaxPath];
    char *buf = static_cast<char *>(out.mutableBytes);
    buf[0] = '\0';  // NPP returns 0 for untitled buffers without writing
    nppData._sendMessage(nppData._nppHandle,
                         NPPM_GETFULLPATHFROMBUFFERID,
                         static_cast<uintptr_t>(bufferId),
                         reinterpret_cast<intptr_t>(buf));
    if (buf[0] == '\0') return nil;
    return [NSString stringWithUTF8String:buf];
}

// True iff the path's tail (case-insensitive) matches any space-separated
// token in g_autoExtensions. Tokens may include or omit the leading dot;
// "log .bin" matches both "foo.log" and "data.bin".
static bool autoExtensionMatches(NSString *path)
{
    if (path.length == 0) return false;
    NSString *list = g_autoExtensions ?: @"";
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *raw in [list componentsSeparatedByCharactersInSet:ws]) {
        NSString *token = [raw stringByTrimmingCharactersInSet:ws];
        if (token.length == 0) continue;
        NSString *needle = [token hasPrefix:@"."] ? token : [@"." stringByAppendingString:token];
        if ([path.lowercaseString hasSuffix:needle.lowercaseString]) {
            return true;
        }
    }
    return false;
}

// True iff the first ~1 MB of `handle`'s buffer contains at least
// (sample * percent / 100) control bytes (< 0x20 except tab/CR/LF). Mirrors
// the Windows IsPercentReached. Skips when the buffer starts with a UTF
// BOM — those buffers are intentionally text and would skew the heuristic.
static bool autoControlCharThresholdReached(NppHandle handle, int percent)
{
    if (percent <= 0 || percent >= 100 || handle == 0) return false;
    const uintptr_t length = static_cast<uintptr_t>(
        nppData._sendMessage(handle, SCI_GETLENGTH, 0, 0));
    if (length == 0) return false;
    const NSUInteger sample = std::min<NSUInteger>(length, HEX_AUTOSTART_SAMPLE_BYTES);
    NSMutableData *buf = [NSMutableData dataWithLength:sample + 1];
    Sci_TextRangeFull range = {};
    range.chrg.cpMin = 0;
    range.chrg.cpMax = static_cast<intptr_t>(sample);
    range.lpstrText = static_cast<char *>(buf.mutableBytes);
    nppData._sendMessage(handle, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<intptr_t>(&range));
    const std::uint8_t *bytes = static_cast<const std::uint8_t *>(buf.bytes);
    // Skip text-leading BOMs (UTF-16 LE/BE, UTF-8). A buffer that opens
    // with a BOM is declared text by the file producer; we trust that.
    if (sample >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                        (bytes[0] == 0xFE && bytes[1] == 0xFF))) return false;
    if (sample >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return false;
    const NSUInteger threshold = (HEX_AUTOSTART_SAMPLE_BYTES * static_cast<NSUInteger>(percent)) / 100;
    NSUInteger ctrlCount = 0;
    for (NSUInteger i = 0; i < sample; ++i) {
        const std::uint8_t b = bytes[i];
        if (b < 0x20 && b != '\t' && b != '\r' && b != '\n') {
            if (++ctrlCount >= threshold) return true;
        }
    }
    return false;
}

static bool isPreviewBufferActive()
{
    return previewScintillaHandle != 0 && previewBufferId != 0 && getCurrentBufferId() == previewBufferId;
}

static NSView *currentEditorView()
{
    const uintptr_t bufferId = getCurrentBufferId();
    if (!bufferId) {
        return nil;
    }

    id object = (__bridge id)(void *)bufferId;
    if ([object isKindOfClass:[NSView class]]) {
        return static_cast<NSView *>(object);
    }

    return nil;
}

static NSView *findScintillaView(NSView *view)
{
    if (!view) {
        return nil;
    }

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"ScintillaView"] || [className containsString:@"Scintilla"]) {
        return view;
    }

    for (NSView *subview in view.subviews) {
        NSView *found = findScintillaView(subview);
        if (found) {
            return found;
        }
    }

    return nil;
}

static bool isHexViewActive()
{
    return hexRootView && hexRootView.superview;
}

static NSPoint currentHexTableScrollOrigin()
{
    if (!hexTableView.enclosingScrollView) {
        return NSZeroPoint;
    }

    return hexTableView.enclosingScrollView.contentView.bounds.origin;
}

static void restoreHexTableScrollOrigin(NSPoint origin)
{
    if (!hexTableView.enclosingScrollView) {
        return;
    }

    NSClipView *clipView = hexTableView.enclosingScrollView.contentView;
    [clipView scrollToPoint:origin];
    [hexTableView.enclosingScrollView reflectScrolledClipView:clipView];
}

static void restoreHexTableScrollOriginLater(NSPoint origin)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        restoreHexTableScrollOrigin(origin);
    });
}

static void resetHexTableScrollOrigin()
{
    // Use scrollRowToVisible: when possible — NSTableView accounts for the
    // floating column-header bar when computing the target scroll position, so
    // row 0 lands just below the header (not behind it). Falling back to
    // scrollToPoint:NSZeroPoint when there are no rows yet is harmless.
    if (hexTableView != nil && hexTableView.numberOfRows > 0) {
        [hexTableView scrollRowToVisible:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hexTableView != nil && hexTableView.numberOfRows > 0) {
                [hexTableView scrollRowToVisible:0];
            }
        });
        return;
    }
    restoreHexTableScrollOrigin(NSZeroPoint);
    restoreHexTableScrollOriginLater(NSZeroPoint);
}

// Scroll the hex table so the row containing `activeByteOffset` is on-screen.
// Used after captureScintillaSelection() to honor the Scintilla caret/selection
// position. The deferred dispatch handles the case where the table's row count
// hasn't settled yet (reloadData propagation runs on the main queue).
static void scrollHexTableToActiveOffset()
{
    if (hexTableView == nil || hexTableView.numberOfRows == 0) {
        resetHexTableScrollOrigin();
        return;
    }
    const auto rowForOffset = ^NSInteger {
        const size_t bpr = static_cast<size_t>(currentBytesPerRow());
        if (bpr == 0) {
            return 0;
        }
        const NSInteger raw = static_cast<NSInteger>(activeByteOffset / bpr);
        const NSInteger maxRow = std::max<NSInteger>(hexTableView.numberOfRows - 1, 0);
        return std::clamp<NSInteger>(raw, 0, maxRow);
    };
    [hexTableView scrollRowToVisible:rowForOffset()];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hexTableView != nil && hexTableView.numberOfRows > 0) {
            [hexTableView scrollRowToVisible:rowForOffset()];
        }
    });
}

static void redrawHexTablePreservingScroll(NSPoint origin)
{
    // reloadData (not just setNeedsDisplay) so NSTableView re-queries the
    // row count. Every caller of this helper sits after a buffer-length
    // change (delete, paste, insert, replace), and setNeedsDisplay alone
    // only repaints currently-known rows — leaving NSTableView's cached
    // row count stale. Symptom when this was missing: pasting 1.5 GB into
    // an empty hex view rendered only the first row, because the table
    // still believed it had 1 row from the pre-paste empty state.
    // reloadData is cheap on a virtual table and cheaper than the bug.
    [hexTableView reloadData];
    [hexTableView setNeedsDisplay:YES];
    restoreHexTableScrollOrigin(origin);
    restoreHexTableScrollOriginLater(origin);
}

static void redrawHexRowsPreservingScroll(size_t firstOffset, size_t secondOffset, NSPoint origin)
{
    if (!hexTableView) {
        return;
    }

    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    const NSInteger firstRow = static_cast<NSInteger>(firstOffset / bpr);
    const NSInteger secondRow = static_cast<NSInteger>(secondOffset / bpr);
    if (firstRow >= 0 && firstRow < hexTableView.numberOfRows) {
        [hexTableView setNeedsDisplayInRect:[hexTableView rectOfRow:firstRow]];
    }
    if (secondRow != firstRow && secondRow >= 0 && secondRow < hexTableView.numberOfRows) {
        [hexTableView setNeedsDisplayInRect:[hexTableView rectOfRow:secondRow]];
    }

    restoreHexTableScrollOrigin(origin);
    restoreHexTableScrollOriginLater(origin);
}

static NSMenuItem *findMenuItemWithTag(NSMenu *menu, NSInteger tag)
{
    if (!menu || tag == 0) {
        return nil;
    }

    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag == tag) {
            return item;
        }

        NSMenuItem *found = findMenuItemWithTag(item.submenu, tag);
        if (found) {
            return found;
        }
    }

    return nil;
}

static void updateHexMenuCheck(bool checked)
{
    NSMenuItem *item = findMenuItemWithTag(NSApp.mainMenu, funcItem[0]._cmdID);
    if (item) {
        item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

static intptr_t sci(NppHandle handle, uint32_t message, uintptr_t wParam = 0, intptr_t lParam = 0)
{
    return nppData._sendMessage(handle, message, wParam, lParam);
}

static CGFloat readEditorFontSize()
{
    NppHandle editor = getCurrentScintilla();
    if (!editor) {
        return HEX_FALLBACK_FONT_SIZE;
    }

    CGFloat size = HEX_FALLBACK_FONT_SIZE;
    const intptr_t fractionalSize = sci(editor, SCI_STYLEGETSIZEFRACTIONAL, STYLE_DEFAULT, 0);
    if (fractionalSize > 0) {
        size = static_cast<CGFloat>(fractionalSize) / 100.0;
    } else {
        const intptr_t integerSize = sci(editor, SCI_STYLEGETSIZE, STYLE_DEFAULT, 0);
        if (integerSize > 0) {
            size = static_cast<CGFloat>(integerSize);
        }
    }

    const intptr_t editorZoom = sci(editor, SCI_GETZOOM, 0, 0);
    size += static_cast<CGFloat>(editorZoom);

    return std::clamp(size, HEX_MIN_FONT_SIZE, HEX_MAX_FONT_SIZE);
}

// Concrete SciReader for the live host-side Scintilla. Buffer-shape logic is
// in hexedit::readPreviewBuffer (HexCore) so it's exercised by ASan-instrumented
// unit tests via a FakeScintilla that obeys the same SCI_GETTEXTRANGEFULL
// contract. Anything that goes wrong with buffer sizing / NUL handling is
// caught at <1 ms unit-test feedback rather than via the 25-minute UI suite.
class LiveSciReader final : public hexedit::SciReader {
public:
    explicit LiveSciReader(NppHandle handle) : handle_(handle) {}

    std::size_t documentLength() const override
    {
        if (!handle_) {
            return 0;
        }
        const intptr_t length = sci(handle_, SCI_GETLENGTH);
        return length > 0 ? static_cast<std::size_t>(length) : 0;
    }

    void readRange(std::size_t cpMin, std::size_t cpMax, char *dest) const override
    {
        Sci_TextRangeFull range = {};
        range.chrg.cpMin = static_cast<Sci_Position>(cpMin);
        range.chrg.cpMax = static_cast<Sci_Position>(cpMax);
        range.lpstrText = dest;
        sci(handle_, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<intptr_t>(&range));
    }

private:
    NppHandle handle_ = 0;
};

// Bind / rebind g_hexBuffer to the active Scintilla. Replaces the legacy
// `previewBytes = readCurrentBuffer(...)` write sites — instead of copying
// the (capped) document into a vector, we wrap the live editor in a
// SciReader and a page-cached source. previewTotalLength stays as a cached
// length for legacy display code; it mirrors g_hexBuffer->length().
//
// Destruction order matters: g_hexBuffer holds a reference into *g_hexReader,
// so we reset g_hexBuffer *before* replacing g_hexReader.
static void bindHexBufferToActiveScintilla()
{
    NppHandle editor = previewScintillaHandle ? previewScintillaHandle : getCurrentScintilla();
    if (!editor) {
        g_hexBuffer.reset();
        g_hexReader.reset();
        previewTotalLength = 0;
        return;
    }
    g_hexBuffer.reset();
    g_hexReader = std::make_unique<LiveSciReader>(editor);
    g_hexBuffer = std::make_unique<hexedit::WindowedScintillaByteSource>(*g_hexReader);
    previewTotalLength = g_hexBuffer->length();
}

// Drop cached pages without rebuilding the SciReader. Use this after a known-
// in-place mutation (SCN_MODIFIED) of the same buffer we're already bound to.
// length() is queried on every call so the freshly-changed document length
// is observed without an explicit refresh.
static void invalidateHexBuffer()
{
    if (g_hexBuffer) {
        g_hexBuffer->invalidate();
        previewTotalLength = g_hexBuffer->length();
    } else {
        bindHexBufferToActiveScintilla();
    }
}

static NSInteger cellColumnIndex(NSString *identifier)
{
    if (![identifier hasPrefix:@"cell"]) {
        return -1;
    }

    return [[identifier substringFromIndex:4] integerValue];
}

static BOOL isVisibleEditableOffset(size_t offset)
{
    return hexedit::isVisibleEditableOffset(currentDocumentView(), offset) ? YES : NO;
}

static BOOL hasByteSelection()
{
    return selectedByteEnd > selectedByteStart;
}

static BOOL isSelectedByte(size_t offset)
{
    return hasByteSelection() && offset >= selectedByteStart && offset < selectedByteEnd;
}

static BOOL hasRectSelection()
{
    return g_rectActive ? YES : NO;
}

// Linear OR rectangular — the broad question editors care about ("is anything selected?").
static BOOL hasAnyByteSelection()
{
    return hasByteSelection() || hasRectSelection();
}

static size_t currentHighlightRow()
{
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    if (hasRectSelection()) {
        // For a rectangle, highlight the row containing the cursor (which tracks the
        // dragged-to / arrow-extended corner) so the focus indicator follows the user's
        // hand rather than always sitting at the rect's geometric end.
        return activeByteOffset / bpr;
    }
    if (hasByteSelection()) {
        return (selectedByteEnd - 1) / bpr;
    }

    return activeByteOffset / bpr;
}

static void clearByteSelection()
{
    selectedByteStart = 0;
    selectedByteEnd = 0;
}

static void clearRectSelection()
{
    g_rectActive = false;
    g_rectSelection = hexedit::RectSelection{};
    g_isSelectingRect = false;
    g_rectAnchorOffset = 0;
    g_rectOriginField = HexCursorField::Hex;
}

static void clearAllByteSelections()
{
    clearByteSelection();
    clearRectSelection();
}

// Build/update the rectangle from the stored anchor + a new endpoint.
static void updateRectSelectionToOffset(size_t endOffset)
{
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    if (bpr == 0) {
        return;
    }
    g_rectSelection = hexedit::makeRectSelection(g_rectAnchorOffset, endOffset, bpr, previewTotalLength);
    g_rectActive = g_rectSelection.active();
    if (g_rectActive) {
        // Track the active cursor at the dragged-to corner so the caret indicator
        // stays under the user's pointer / arrow keys.
        activeByteOffset = std::min(endOffset, previewTotalLength > 0 ? previewTotalLength - 1 : 0);
        activeHexNibble = 0;
        activeCursorField = g_rectOriginField;
        clampActiveCursor();
    }
    if (hexTableView) {
        [hexTableView setNeedsDisplay:YES];
    }
}

static void captureScintillaSelection()
{
    // Mirror the host's caret + selection state into the hex view so the transition
    // preserves where the user was working:
    //   - Caret only (no selection): hex cursor lands on that byte; no selection.
    //   - Real selection: hex view shows the same byte range highlighted, and the
    //     hex cursor lands at the END of the selection (matching the typical caret
    //     placement after an extend-selection in Scintilla).
    // The caller is responsible for scrolling the chosen byte into view.
    clearByteSelection();
    lastScintillaSelStart = -1;
    lastScintillaSelEnd = -1;
    lastScintillaCaret = -1;
    if (!previewScintillaHandle) {
        return;
    }

    const intptr_t start = sci(previewScintillaHandle, SCI_GETSELECTIONSTART, 0, 0);
    const intptr_t end = sci(previewScintillaHandle, SCI_GETSELECTIONEND, 0, 0);
    const intptr_t caret = sci(previewScintillaHandle, SCI_GETCURRENTPOS, 0, 0);
    lastScintillaSelStart = start;
    lastScintillaSelEnd = end;
    lastScintillaCaret = caret;
    if (start < 0 || end < 0) {
        return;
    }

    const size_t lower = static_cast<size_t>(std::min(start, end));
    const size_t upper = static_cast<size_t>(std::max(start, end));

    activeCursorField = HexCursorField::Hex;
    activeHexNibble = 0;
    activeByteOffset = std::min(upper, hexBufferLength());

    if (start != end) {
        selectedByteStart = std::min(lower, hexBufferLength());
        selectedByteEnd = std::min(upper, hexBufferLength());
        if (selectedByteEnd <= selectedByteStart) {
            clearByteSelection();
        }
    }

    clampActiveCursor();
}

static BOOL isBookmarkedRow(size_t row)
{
    return bookmarkedRows.find(row) != bookmarkedRows.end();
}

static void toggleBookmarkRow(size_t row)
{
    auto existing = bookmarkedRows.find(row);
    if (existing == bookmarkedRows.end()) {
        bookmarkedRows.insert(row);
    } else {
        bookmarkedRows.erase(existing);
    }
}

static void clampActiveCursor()
{
    writeBackCursor(hexedit::clampCursor(currentCursor(), currentDocumentView(), currentViewMode()));
}

static void setActiveHexCursor(size_t offset, NSInteger nibble)
{
    asciiAltNumpadValue = -1;
    activeCursorField = HexCursorField::Hex;
    activeByteOffset = offset;
    activeHexNibble = nibble;
    clampActiveCursor();
}

static void setActiveAsciiCursor(size_t offset)
{
    asciiAltNumpadValue = -1;
    activeCursorField = HexCursorField::Ascii;
    activeByteOffset = offset;
    activeHexNibble = 0;
    clampActiveCursor();
}

static void moveActiveCursor(NSInteger delta)
{
    writeBackCursor(hexedit::moveCursor(currentCursor(), static_cast<long>(delta), currentDocumentView()));
}

static hexedit::DocumentView currentDocumentView()
{
    hexedit::DocumentView view;
    view.source = g_hexBuffer.get();
    view.visibleByteCount = hexBufferLength();
    view.totalLength = previewTotalLength;
    return view;
}

static hexedit::Selection currentSelection()
{
    hexedit::Selection sel;
    sel.start = selectedByteStart;
    sel.end = selectedByteEnd;
    return sel;
}

static hexedit::CursorState currentCursor()
{
    hexedit::CursorState cursor;
    cursor.offset = activeByteOffset;
    cursor.nibble = static_cast<int>(activeHexNibble);
    cursor.field = activeCursorField == HexCursorField::Hex ? hexedit::CursorField::Hex : hexedit::CursorField::Ascii;
    return cursor;
}

static void writeBackCursor(const hexedit::CursorState &cursor)
{
    activeByteOffset = cursor.offset;
    activeHexNibble = static_cast<NSInteger>(cursor.nibble);
    activeCursorField = cursor.field == hexedit::CursorField::Hex ? HexCursorField::Hex : HexCursorField::Ascii;
}

static bool replaceEditorBytes(size_t offset, const uint8_t *bytes, size_t byteCount, size_t replacedByteCount)
{
    return byteCount > 0 && applyEditorByteTransaction(offset, bytes, byteCount, replacedByteCount);
}

static bool deleteEditorBytes(size_t offset, size_t byteCount)
{
    if (byteCount == 0 || !applyEditorByteTransaction(offset, nullptr, 0, byteCount)) {
        return false;
    }

    activeByteOffset = std::min(offset, previewTotalLength);
    activeHexNibble = 0;
    clearByteSelection();
    redrawHexTablePreservingScroll(currentHexTableScrollOrigin());
    return true;
}

static bool applyEditorByteTransaction(size_t offset, const uint8_t *bytes, size_t byteCount, size_t replacedByteCount)
{
    if (!isPreviewBufferActive()) {
        return false;
    }

    NppHandle editor = previewScintillaHandle;
    if (!editor || (byteCount > 0 && !bytes) || (byteCount == 0 && replacedByteCount == 0)) {
        return false;
    }

    const intptr_t length = sci(editor, SCI_GETLENGTH);
    if (length < 0 || offset > static_cast<size_t>(length) || replacedByteCount > static_cast<size_t>(length) - offset) {
        return false;
    }

    suppressModificationRefresh = true;
    sci(editor, SCI_BEGINUNDOACTION);
    sci(editor, SCI_SETTARGETSTART, offset, 0);
    sci(editor, SCI_SETTARGETEND, offset + replacedByteCount, 0);
    sci(editor, SCI_REPLACETARGET, byteCount, reinterpret_cast<intptr_t>(bytes));
    sci(editor, SCI_ENDUNDOACTION);
    suppressModificationRefresh = false;

    bindHexBufferToActiveScintilla();
    clampActiveCursor();
    if (hexStatusLabel) {
        hexStatusLabel.stringValue = makeStatusText();
    }
    return true;
}

static void refreshHexViewFromScintilla(size_t preferredCursorOffset, NSPoint scrollOrigin)
{
    bindHexBufferToActiveScintilla();
    activeByteOffset = std::min(preferredCursorOffset, previewTotalLength);
    activeHexNibble = 0;
    clearByteSelection();
    clampActiveCursor();
    if (hexStatusLabel) {
        hexStatusLabel.stringValue = makeStatusText();
    }
    redrawHexTablePreservingScroll(scrollOrigin);
}

static bool performScintillaUndoRedo(uint32_t message)
{
    if (!isPreviewBufferActive() || (message != SCI_UNDO && message != SCI_REDO)) {
        return false;
    }

    const uint32_t canMessage = message == SCI_UNDO ? SCI_CANUNDO : SCI_CANREDO;
    if (!canPerformScintillaUndoRedo(canMessage)) {
        return false;
    }

    const NSPoint scrollOrigin = currentHexTableScrollOrigin();
    const size_t preferredCursorOffset = activeByteOffset;
    suppressModificationRefresh = true;
    sci(previewScintillaHandle, message, 0, 0);
    suppressModificationRefresh = false;
    refreshHexViewFromScintilla(preferredCursorOffset, scrollOrigin);
    return true;
}

static bool canPerformScintillaUndoRedo(uint32_t message)
{
    if (!isPreviewBufferActive() || (message != SCI_CANUNDO && message != SCI_CANREDO)) {
        return false;
    }

    return sci(previewScintillaHandle, message, 0, 0) != 0;
}

static void selectedOrCurrentRange(size_t *offset, size_t *byteCount)
{
    hexedit::ByteRange range = hexedit::selectedOrCurrentRange(currentDocumentView(), currentCursor(), currentSelection());
    *offset = range.offset;
    *byteCount = range.byteCount;
}

// Adapter that wraps hexedit::encodeRectPayload (pure C++) into an NSData. Kept
// here rather than inline at the call site so the AppKit / Foundation dependency
// stays out of the C++ core layer, where the encoder is unit-tested + fuzzed.
static NSData *rectPayloadEncode(HexRectClipboardKind kind,
                                 std::uint32_t width,
                                 std::uint32_t height,
                                 const std::uint8_t *data,
                                 std::uint32_t dataLength)
{
    std::vector<std::uint8_t> payload =
        hexedit::encodeRectPayload(kind, width, height, data, dataLength);
    return [NSData dataWithBytes:payload.data() length:payload.size()];
}

// Adapter for hexedit::decodeRectPayload. Returns NO on malformed input (bad
// magic, version mismatch, truncated header, dataLength > buffer size) — all
// validation logic lives in the core function so libFuzzer can exercise it
// without an AppKit dependency.
static BOOL rectPayloadDecode(NSData *data,
                              HexRectClipboardKind *outKind,
                              std::uint32_t *outWidth,
                              std::uint32_t *outHeight,
                              const std::uint8_t **outDataPtr,
                              std::uint32_t *outDataLength)
{
    if (data == nil) {
        return NO;
    }
    hexedit::RectPayload payload;
    if (!hexedit::decodeRectPayload(static_cast<const std::uint8_t *>(data.bytes),
                                     data.length, payload)) {
        return NO;
    }
    if (outKind) *outKind = payload.kind;
    if (outWidth) *outWidth = payload.width;
    if (outHeight) *outHeight = payload.height;
    if (outDataPtr) *outDataPtr = payload.data;
    if (outDataLength) *outDataLength = payload.dataLength;
    return YES;
}

// Promised-type pasteboard owner for hex-view cut/copy. Replaces the old
// eager `[pasteboard setData:forType:]` path: instead of materializing every
// representation (raw bytes, hex-text, rect-UTI) at copy time, we declare
// the supported types and stash one byte snapshot inside the owner. When
// some consumer (this plugin, another HexEditor instance, TextEdit, anything
// reading the pasteboard) actually pastes, AppKit's pasteboard server calls
// back to `pasteboard:provideDataForType:` and we synthesize the requested
// representation lazily. Cross-process consumers get the callback via pbs
// IPC for free.
//
// Lifetime: a single static owner instance lives for the plugin's lifetime;
// `snapshotLinear:` / `snapshotRect:...` reassign its held bytes on each
// new cut/copy, replacing whatever was there. AppKit notifies us via
// `pasteboardChangedOwner:` when another app takes the pasteboard, at
// which point we drop the snapshot — there's no consumer left to deliver
// to.
//
// hex-text caps: rendering an N-byte selection as space-separated hex
// expands to ~3N bytes of UTF-8. For a multi-GB cut that's a multi-GB
// allocation just to hand to a text-paste consumer that probably can't
// handle it anyway. Above kHexClipboardTextRawCap we substitute a short
// human-readable placeholder so a stray paste into TextEdit shows
// "<2.0 GB hex-editor selection> Paste in HEX view to receive." instead
// of a multi-GB string allocation.
constexpr NSUInteger kHexClipboardTextRawCap = 16 * 1024 * 1024;

@interface HexClipboardOwner : NSObject <NSPasteboardTypeOwner>
- (void)snapshotLinear:(NSData *)bytes;
- (void)snapshotRect:(NSData *)bytes
                kind:(HexRectClipboardKind)kind
               width:(std::uint32_t)width
              height:(std::uint32_t)height;
- (void)clearSnapshot;
- (BOOL)hasSnapshot;
- (NSUInteger)snapshotByteCount;
// In-process readers — let pasteBytesFromPasteboard short-circuit pbs IPC
// for hex→hex paste in the same NPP process. pbs's IPC transport breaks
// down somewhere in the multi-100-MB range; the snapshot lives in this
// process's heap and is readable instantly regardless of size.
- (NSData *)snapshotBytes;
- (BOOL)snapshotIsRect;
- (HexRectClipboardKind)snapshotRectKind;
- (std::uint32_t)snapshotRectWidth;
- (std::uint32_t)snapshotRectHeight;
@end

// changeCount returned by `[pasteboard declareTypes:owner:]` at the moment
// we took ownership of the general pasteboard. Stays valid until any other
// process or any other in-process pasteboard write bumps the count.
// Compared against `pasteboard.changeCount` in the paste path: if it still
// matches, our snapshot is authoritative and we can read directly from it
// instead of going through pbs IPC (which silently drops public.data
// payloads in the multi-100-MB range — see comment in
// pasteFromInProcessSnapshotIfOwner). Sentinel -1 means "we never owned
// the pasteboard," which is impossible to match an actual changeCount
// (those start at 1 and only increase).
static NSInteger g_hexClipboardChangeCount = -1;

@implementation HexClipboardOwner {
    NSData *_bytes;
    BOOL _isRect;
    HexRectClipboardKind _rectKind;
    std::uint32_t _rectWidth;
    std::uint32_t _rectHeight;
}

- (void)snapshotLinear:(NSData *)bytes
{
    _bytes = [bytes copy];
    _isRect = NO;
    _rectKind = HexRectClipboardKind::Bytes;
    _rectWidth = 0;
    _rectHeight = 0;
}

- (void)snapshotRect:(NSData *)bytes
                kind:(HexRectClipboardKind)kind
               width:(std::uint32_t)width
              height:(std::uint32_t)height
{
    _bytes = [bytes copy];
    _isRect = YES;
    _rectKind = kind;
    _rectWidth = width;
    _rectHeight = height;
}

- (void)clearSnapshot
{
    _bytes = nil;
    _isRect = NO;
    _rectKind = HexRectClipboardKind::Bytes;
    _rectWidth = 0;
    _rectHeight = 0;
}

- (BOOL)hasSnapshot
{
    return _bytes != nil;
}

- (NSUInteger)snapshotByteCount
{
    return _bytes.length;
}

- (NSData *)snapshotBytes
{
    return _bytes;
}

- (BOOL)snapshotIsRect
{
    return _isRect;
}

- (HexRectClipboardKind)snapshotRectKind
{
    return _rectKind;
}

- (std::uint32_t)snapshotRectWidth
{
    return _rectWidth;
}

- (std::uint32_t)snapshotRectHeight
{
    return _rectHeight;
}

// AppKit calls this once per requested type per paste, possibly cross-
// process via pbs IPC. We synthesize the rendering on demand from the
// held snapshot — no upfront materialization, no duplicate copies.
- (void)pasteboard:(NSPasteboard *)pasteboard provideDataForType:(NSPasteboardType)type
{
    if (_bytes == nil) {
        return;
    }

    if ([type isEqualToString:NSPasteboardTypeString]) {
        if (_bytes.length > kHexClipboardTextRawCap) {
            // Above the hex-text cap: emit a placeholder so a text-paste
            // consumer sees a clear "this came from HEX-Editor — paste in
            // HEX view to receive" sentence rather than a multi-GB string.
            NSString *placeholder = [NSString stringWithFormat:
                @"<%.1f MB hex-editor selection> Paste into HEX view to receive.",
                (double)_bytes.length / (1024.0 * 1024.0)];
            [pasteboard setString:placeholder forType:type];
            return;
        }
        std::string text;
        if (_isRect && _rectWidth > 0 && _rectHeight > 0) {
            // Rect: row-separated hex via the existing core formatter.
            // The snapshot is densely packed (bytesPerRow == width).
            hexedit::SpanByteSource source(
                static_cast<const std::uint8_t *>(_bytes.bytes), _bytes.length);
            hexedit::RectSelection rect;
            rect.originOffset = 0;
            rect.width = _rectWidth;
            rect.height = _rectHeight;
            rect.bytesPerRow = _rectWidth;
            text = hexedit::formatRectClipboardHex(source, rect);
        } else {
            text = hexedit::formatHexClipboardText(
                static_cast<const std::uint8_t *>(_bytes.bytes), _bytes.length);
        }
        NSString *string = [NSString stringWithUTF8String:text.c_str()];
        if (string != nil) {
            [pasteboard setString:string forType:type];
        }
        return;
    }

    if ([type isEqualToString:@"public.data"]) {
        [pasteboard setData:_bytes forType:type];
        return;
    }

    if ([type isEqualToString:kHexRectPasteboardType] && _isRect) {
        NSData *encoded = rectPayloadEncode(_rectKind, _rectWidth, _rectHeight,
            static_cast<const std::uint8_t *>(_bytes.bytes),
            static_cast<std::uint32_t>(_bytes.length));
        if (encoded != nil) {
            [pasteboard setData:encoded forType:type];
        }
        return;
    }
}

// AppKit notifies us when ownership lapses (some other app declared types).
// Drop the snapshot — there's no consumer left to deliver to.
- (void)pasteboardChangedOwner:(NSPasteboard *)sender
{
    (void)sender;
    [self clearSnapshot];
    // Invalidate the change-count sentinel too, so the in-process
    // short-circuit in pasteFromInProcessSnapshotIfOwner can't read a
    // stale snapshot if some path forgets to call clearSnapshot.
    g_hexClipboardChangeCount = -1;
}
@end

// Single static instance, lazily created on first cut/copy. Rebuilt only
// across plugin loads, never per-cut.
static HexClipboardOwner *g_hexClipboardOwner = nil;

static HexClipboardOwner *sharedHexClipboardOwner()
{
    if (g_hexClipboardOwner == nil) {
        g_hexClipboardOwner = [[HexClipboardOwner alloc] init];
    }
    return g_hexClipboardOwner;
}

// Office/Word pattern: when we hold an outstanding pasteboard promise at
// process quit, the bytes vanish unless we materialize them onto the
// pasteboard before exit. For small snapshots (≤ this threshold) we
// materialize silently — no user friction. For larger snapshots, we ask
// the user whether to keep them on the clipboard or let them go.
constexpr NSUInteger kHexClipboardSilentMaterializeCap = 16 * 1024 * 1024;

// Iterate the declared types and resolve each by calling the owner's
// provideDataForType:. After this returns, the pasteboard holds actual
// data (not a promise), so the data survives our process exit.
static void resolveAllHexClipboardPromises()
{
    HexClipboardOwner *owner = g_hexClipboardOwner;
    if (owner == nil || ![owner hasSnapshot]) {
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSArray<NSPasteboardType> *types = pasteboard.types;
    for (NSPasteboardType type in types) {
        [owner pasteboard:pasteboard provideDataForType:type];
    }
}

static void materializeHexClipboardOnQuitIfNeeded()
{
    HexClipboardOwner *owner = g_hexClipboardOwner;
    if (owner == nil || ![owner hasSnapshot]) {
        return;
    }
    const NSUInteger byteCount = [owner snapshotByteCount];
    if (byteCount == 0) {
        return;
    }
    if (byteCount <= kHexClipboardSilentMaterializeCap) {
        // Small enough to materialize without bothering the user.
        resolveAllHexClipboardPromises();
        return;
    }

    // Show the user the size in human-readable form (MB / GB depending on
    // scale) so the modal communicates the cost concretely.
    NSString *sizeText = nil;
    constexpr double kGB = 1024.0 * 1024.0 * 1024.0;
    if (byteCount >= static_cast<NSUInteger>(kGB)) {
        sizeText = [NSString stringWithFormat:@"%.1f GB", (double)byteCount / kGB];
    } else {
        sizeText = [NSString stringWithFormat:@"%.1f MB",
                    (double)byteCount / (1024.0 * 1024.0)];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = L(@"clipboard.saveOnQuit.title");
    alert.informativeText = [NSString stringWithFormat:L(@"clipboard.saveOnQuit.body"),
                             sizeText];
    [alert addButtonWithTitle:L(@"clipboard.saveOnQuit.keepButton")];
    [alert addButtonWithTitle:L(@"clipboard.saveOnQuit.discardButton")];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        resolveAllHexClipboardPromises();
    }
    // If "Discard": the promise lapses on process exit; the pasteboard
    // returns no data for our types after we're gone.
}

// Copy the active rectangular selection to the system pasteboard. Always emits the
// custom UTI (so paste-back into this plugin gets the exact shape) plus a public-text
// fallback (space-separated hex bytes per row) for external apps. The source-pane tag
// distinguishes Bytes vs. Ascii so paste-back can preserve which pane drove the copy,
// but the text representation is identical (hex bytes always — ASCII characters can
// include unprintable bytes that would render as dots and lose the original data).
static bool copyRectToPasteboard()
{
    if (!hasRectSelection()) {
        return false;
    }
    const HexRectClipboardKind kind = (g_rectOriginField == HexCursorField::Ascii)
        ? HexRectClipboardKind::Ascii
        : HexRectClipboardKind::Bytes;

    const hexedit::ByteSource &bufferSource = hexBufferSource();
    std::vector<std::uint8_t> payloadBytes;
    hexedit::extractRectBytes(bufferSource, g_rectSelection, payloadBytes);

    NSData *bytesNS = [NSData dataWithBytes:(payloadBytes.empty() ? nullptr : payloadBytes.data())
                                     length:payloadBytes.size()];
    HexClipboardOwner *owner = sharedHexClipboardOwner();
    [owner snapshotRect:bytesNS
                   kind:kind
                  width:static_cast<std::uint32_t>(g_rectSelection.width)
                 height:static_cast<std::uint32_t>(g_rectSelection.height)];

    // Promise types — pbs will call provideDataForType: on the owner when
    // some consumer pastes. No bytes hit the pasteboard upfront. Capture
    // the changeCount so an in-process paste can recognize that we still
    // own the pasteboard and read the snapshot directly (bypassing pbs).
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    g_hexClipboardChangeCount =
        [pasteboard declareTypes:@[NSPasteboardTypeString, kHexRectPasteboardType] owner:owner];
    return true;
}

static bool copyHexSelectionToPasteboard()
{
    if (hasRectSelection()) {
        return copyRectToPasteboard();
    }

    size_t offset = 0;
    size_t byteCount = 0;
    selectedOrCurrentRange(&offset, &byteCount);
    if (byteCount == 0 || offset >= hexBufferLength()) {
        return false;
    }

    byteCount = std::min(byteCount, hexBufferLength() - offset);
    // Snapshot the selection into a contiguous NSMutableData. We can't take
    // a raw pointer into the page-cached source because pages may evict
    // during the read; copying into NSMutableData snapshots the selection
    // at copy time, which is what the pasteboard owner needs anyway.
    NSMutableData *selectionBytes = [NSMutableData dataWithLength:byteCount];
    hexBytesIn(offset, byteCount, static_cast<std::uint8_t *>(selectionBytes.mutableBytes));

    HexClipboardOwner *owner = sharedHexClipboardOwner();
    [owner snapshotLinear:selectionBytes];

    // Promise types — pbs will call provideDataForType: on the owner when
    // some consumer pastes. The hex-text and raw-bytes renderings are
    // synthesized lazily inside the owner from the snapshot. Capture the
    // changeCount so an in-process paste can recognize that we still own
    // the pasteboard and read the snapshot directly (bypassing pbs IPC,
    // which truncates public.data above ~few hundred MB).
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    g_hexClipboardChangeCount =
        [pasteboard declareTypes:@[NSPasteboardTypeString, @"public.data"] owner:owner];
    return true;
}

static bool copyHexSelectionAsBinary()
{
    if (hasRectSelection()) {
        // Binary copy of a rect: same payload as text copy (custom UTI preserves
        // shape) plus the contiguous raw bytes on `public.data` for external apps.
        // Source-pane tag stays whatever the rect's drag origin was.
        if (!copyRectToPasteboard()) {
            return false;
        }
        const hexedit::ByteSource &bufferSource = hexBufferSource();
        std::vector<std::uint8_t> rectBytes;
        if (hexedit::extractRectBytes(bufferSource, g_rectSelection, rectBytes) && !rectBytes.empty()) {
            NSData *raw = [NSData dataWithBytes:rectBytes.data() length:rectBytes.size()];
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard setData:raw forType:@"public.data"];
        }
        return true;
    }

    size_t offset = 0;
    size_t byteCount = 0;
    selectedOrCurrentRange(&offset, &byteCount);
    if (byteCount == 0 || offset >= hexBufferLength()) {
        return false;
    }

    byteCount = std::min(byteCount, hexBufferLength() - offset);
    NSMutableData *bytes = [NSMutableData dataWithLength:byteCount];
    hexBytesIn(offset, byteCount, static_cast<std::uint8_t *>(bytes.mutableBytes));
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setData:bytes forType:NSPasteboardTypeString];
    [pasteboard setData:bytes forType:@"public.data"];
    return true;
}

// Zero-fill the bytes inside the active rectangle. Preserves file size (offsets do
// not shift) — that's the user's spec from the chunk-3 plan: "Block delete semantics
// — zero-fill (preserve offsets)". Leaves the rect itself selected so a second
// Delete (or Cut) is a no-op rather than a footgun.
static bool deleteRectSelection()
{
    if (!hasRectSelection()) {
        return false;
    }
    std::vector<std::uint8_t> zeros(g_rectSelection.totalBytes(), 0);
    if (!applyRectBytesPaste(g_rectSelection, zeros.data(), zeros.size())) {
        return false;
    }
    if (hexTableView) {
        [hexTableView setNeedsDisplay:YES];
    }
    return true;
}

static bool deleteHexSelection()
{
    if (hasRectSelection()) {
        return deleteRectSelection();
    }

    hexedit::ByteEditOperation op;
    if (!hexedit::planDeleteEdit(currentDocumentView(), currentCursor(), currentSelection(), op)) {
        return false;
    }

    if (!applyEditorByteTransaction(op.offset, nullptr, 0, op.replacedByteCount)) {
        return false;
    }

    clearByteSelection();
    writeBackCursor(hexedit::clampCursor(op.nextCursor, currentDocumentView(), currentViewMode()));
    redrawHexTablePreservingScroll(currentHexTableScrollOrigin());
    return true;
}

static bool cutHexSelection()
{
    if (!copyHexSelectionToPasteboard()) {
        return false;
    }
    return deleteHexSelection();
}

static bool cutHexSelectionBinary()
{
    if (!copyHexSelectionAsBinary()) {
        return false;
    }
    return deleteHexSelection();
}

static bool applyBytesPaste(const std::uint8_t *bytes, size_t byteCount)
{
    if (bytes == nullptr || byteCount == 0) {
        return false;
    }

    hexedit::ByteEditOperation op;
    if (!hexedit::planPasteEdit(currentDocumentView(), currentCursor(), currentSelection(),
                                 bytes, byteCount, op)) {
        return false;
    }

    if (!replaceEditorBytes(op.offset, op.replacement.data(), op.replacement.size(), op.replacedByteCount)) {
        return false;
    }

    clearByteSelection();
    hexedit::CursorState reclamped = op.nextCursor;
    reclamped.offset = std::min(op.offset + byteCount, previewTotalLength);
    writeBackCursor(hexedit::clampCursor(reclamped, currentDocumentView(), currentViewMode()));
    redrawHexTablePreservingScroll(currentHexTableScrollOrigin());
    return true;
}

// Apply a paste-time rectangle: write `bytes` (length width*height) into the rows
// of `dest` row-by-row, replacing existing bytes. Out-of-range tail rows are clipped
// to file end (we do not auto-extend the file). Caller has already verified shape
// matches, so this never partially writes — either every row succeeds or none.
static bool applyRectBytesPaste(const hexedit::RectSelection &dest,
                                const std::uint8_t *bytes,
                                std::size_t byteCount)
{
    if (!dest.active() || bytes == nullptr || byteCount != dest.totalBytes()) {
        return false;
    }
    // Build one combined edit op from the per-row writes by emitting a single
    // contiguous transaction whose extent is the rect's bounding-box bytes within
    // each row. Easier: apply each row separately. This may produce N undo records
    // but matches how Insert Columns / Pattern Replace already work.
    suppressModificationRefresh = true;
    bool ok = true;
    for (std::size_t r = 0; r < dest.height; ++r) {
        const std::size_t rowStartOffset = dest.originOffset + r * dest.bytesPerRow;
        if (rowStartOffset >= previewTotalLength) {
            // Remaining rows are entirely past EOF; we don't extend the file, so stop.
            break;
        }
        const std::size_t available = previewTotalLength - rowStartOffset;
        const std::size_t take = std::min(dest.width, available);
        if (!replaceEditorBytes(rowStartOffset, bytes + r * dest.width, take, take)) {
            ok = false;
            break;
        }
    }
    suppressModificationRefresh = false;
    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }
    return ok;
}

// Returns the owner if we still hold the general pasteboard and have a
// live snapshot — i.e., the most recent declareTypes:owner: call was ours
// AND no other writer has bumped the changeCount since. In that case the
// caller can read snapshotBytes directly and skip pbs IPC, which silently
// truncates public.data above ~few-hundred-MB and is the root cause of
// hex→hex paste failing for multi-GB selections.
static HexClipboardOwner *currentlyOwnedHexSnapshot()
{
    HexClipboardOwner *owner = g_hexClipboardOwner;
    if (owner == nil || ![owner hasSnapshot]) {
        return nil;
    }
    if (g_hexClipboardChangeCount < 0) {
        return nil;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard.changeCount != g_hexClipboardChangeCount) {
        return nil;
    }
    return owner;
}

// Strict-shape rectangular paste path. Returns true when the paste landed (success
// OR a user-facing error dialog was presented), false to fall through to the linear
// paste path. The matrix:
//   - Source kind = Addresses → reject.
//   - Destination is not a rect → reject (must be rect).
//   - Destination is rect but shape mismatches → reject (must be exactly w×h).
//   - Destination is rect and shape matches → write bytes.
// If no custom-UTI payload is present but the public-text payload parses as a rect
// per Q2.b, treat it as a kind=Bytes payload and apply the same rules.
static bool tryRectPasteFromPasteboard()
{
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];

    HexRectClipboardKind kind = HexRectClipboardKind::Bytes;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    const std::uint8_t *dataPtr = nullptr;
    std::uint32_t dataLength = 0;
    std::vector<std::uint8_t> textParsedBytes;

    // In-process short-circuit: if we still own the pasteboard and our
    // snapshot is a rect, read it directly. The owner outlives this
    // function (static), so dataPtr stays valid through applyRectBytesPaste.
    HexClipboardOwner *ownedSnapshot = currentlyOwnedHexSnapshot();
    BOOL haveStructured = NO;
    if (ownedSnapshot != nil && [ownedSnapshot snapshotIsRect]) {
        NSData *snapshot = [ownedSnapshot snapshotBytes];
        kind = [ownedSnapshot snapshotRectKind];
        width = [ownedSnapshot snapshotRectWidth];
        height = [ownedSnapshot snapshotRectHeight];
        dataPtr = static_cast<const std::uint8_t *>(snapshot.bytes);
        dataLength = static_cast<std::uint32_t>(snapshot.length);
        haveStructured = YES;
    } else {
        NSData *encoded = [pasteboard dataForType:kHexRectPasteboardType];
        haveStructured = rectPayloadDecode(encoded, &kind, &width, &height, &dataPtr, &dataLength);
    }

    if (!haveStructured) {
        // Q2.b — try parsing public-text as a `\n`-separated rect.
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (text == nil || text.length == 0) {
            return false;
        }
        std::size_t parsedW = 0;
        std::size_t parsedH = 0;
        if (!hexedit::parseRectClipboardText(std::string([text UTF8String]),
                                              textParsedBytes, parsedW, parsedH)) {
            return false;
        }
        if (textParsedBytes.empty() || parsedH < 2) {
            // Single-line text isn't a rectangle — defer to the linear paste path.
            return false;
        }
        kind = HexRectClipboardKind::Bytes;
        width = static_cast<std::uint32_t>(parsedW);
        height = static_cast<std::uint32_t>(parsedH);
        dataPtr = textParsedBytes.data();
        dataLength = static_cast<std::uint32_t>(textParsedBytes.size());
    }

    if (!hasRectSelection()) {
        // Destination is a caret or linear selection — strict matrix rejects this
        // for any rect-typed payload. Tell the user what shape they need.
        presentHexValidationError([NSString stringWithFormat:L(@"paste.rect.errorNeedsRectDestination"),
            (unsigned long)width, (unsigned long)height]);
        return true;
    }

    if (g_rectSelection.width != width || g_rectSelection.height != height) {
        presentHexValidationError([NSString stringWithFormat:L(@"paste.rect.errorShapeMismatch"),
            (unsigned long)width, (unsigned long)height]);
        return true;
    }

    // Guard the dataLength == width × height check against uint32 overflow:
    // a crafted payload with width = 0xFFFFFFFE, height = 2 wraps the product
    // to 0xFFFFFFFC, which a forged dataLength of the same value would slip
    // past — and the downstream applyRectBytesPaste would then index as
    // size_t (no overflow) into an attacker-sized region. Promote to uint64
    // before multiplying so the overflow surfaces here instead.
    const std::uint64_t expectedDataBytes =
        static_cast<std::uint64_t>(width) * static_cast<std::uint64_t>(height);
    if (dataPtr == nullptr || expectedDataBytes != dataLength) {
        presentHexValidationError([NSString stringWithFormat:L(@"paste.rect.errorShapeMismatch"),
            (unsigned long)width, (unsigned long)height]);
        return true;
    }

    if (applyRectBytesPaste(g_rectSelection, dataPtr, dataLength)) {
        // Keep the rect selected after paste so the user can repeat or visually
        // confirm. (Symmetric with how Pattern Replace clears its selection — see
        // chunk 4 — but for paste, leaving the selection feels less surprising.)
        if (hexTableView) {
            [hexTableView setNeedsDisplay:YES];
        }
    }
    return true;
}

static bool pasteBytesFromPasteboard()
{
    if (tryRectPasteFromPasteboard()) {
        return true;
    }

    // In-process short-circuit: if we own the pasteboard and have a
    // linear snapshot, read it directly. Bypasses pbs IPC, which silently
    // drops public.data payloads in the multi-100-MB range and would
    // otherwise force a fall-through to the placeholder string at
    // multi-GB sizes.
    HexClipboardOwner *ownedSnapshot = currentlyOwnedHexSnapshot();
    if (ownedSnapshot != nil && ![ownedSnapshot snapshotIsRect]) {
        NSData *snapshot = [ownedSnapshot snapshotBytes];
        if (snapshot.length > 0) {
            return applyBytesPaste(static_cast<const std::uint8_t *>(snapshot.bytes),
                                   snapshot.length);
        }
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];

    NSData *raw = [pasteboard dataForType:@"public.data"];
    if (raw && raw.length > 0) {
        return applyBytesPaste(static_cast<const std::uint8_t *>(raw.bytes), raw.length);
    }

    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (text && text.length > 0) {
        std::string utf8([text UTF8String]);
        std::vector<std::uint8_t> parsed;
        if (hexedit::parseHexClipboardText(utf8, parsed) && !parsed.empty()) {
            return applyBytesPaste(parsed.data(), parsed.size());
        }
        NSData *utf8Data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8Data && utf8Data.length > 0) {
            return applyBytesPaste(static_cast<const std::uint8_t *>(utf8Data.bytes), utf8Data.length);
        }
    }

    NSData *fallback = [pasteboard dataForType:NSPasteboardTypeString];
    if (fallback && fallback.length > 0) {
        return applyBytesPaste(static_cast<const std::uint8_t *>(fallback.bytes), fallback.length);
    }

    return false;
}

static bool pasteBinaryFromPasteboard()
{
    if (tryRectPasteFromPasteboard()) {
        return true;
    }

    // In-process short-circuit — see pasteBytesFromPasteboard for why.
    HexClipboardOwner *ownedSnapshot = currentlyOwnedHexSnapshot();
    if (ownedSnapshot != nil && ![ownedSnapshot snapshotIsRect]) {
        NSData *snapshot = [ownedSnapshot snapshotBytes];
        if (snapshot.length > 0) {
            return applyBytesPaste(static_cast<const std::uint8_t *>(snapshot.bytes),
                                   snapshot.length);
        }
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];

    NSData *raw = [pasteboard dataForType:@"public.data"];
    if (raw && raw.length > 0) {
        return applyBytesPaste(static_cast<const std::uint8_t *>(raw.bytes), raw.length);
    }

    NSData *stringBytes = [pasteboard dataForType:NSPasteboardTypeString];
    if (stringBytes && stringBytes.length > 0) {
        return applyBytesPaste(static_cast<const std::uint8_t *>(stringBytes.bytes), stringBytes.length);
    }

    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (text && text.length > 0) {
        NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8 && utf8.length > 0) {
            return applyBytesPaste(static_cast<const std::uint8_t *>(utf8.bytes), utf8.length);
        }
    }

    return false;
}

static void selectAllHexBytes()
{
    selectedByteStart = 0;
    selectedByteEnd = hexBufferLength();
    activeCursorField = HexCursorField::Hex;
    activeByteOffset = selectedByteEnd;
    activeHexNibble = 0;
    [hexTableView setNeedsDisplay:YES];
}

static bool handleHexDigit(unichar character)
{
    hexedit::ByteEditOperation op;
    if (!hexedit::planHexDigitEdit(currentDocumentView(), currentCursor(), currentSelection(), hexedit::hexDigitValue(character), op)) {
        return false;
    }

    if (!replaceEditorBytes(op.offset, op.replacement.data(), op.replacement.size(), op.replacedByteCount)) {
        return false;
    }

    clearByteSelection();
    writeBackCursor(hexedit::clampCursor(op.nextCursor, currentDocumentView(), currentViewMode()));
    return true;
}

static bool handleBinaryDigit(unichar character)
{
    int bitValue;
    if (character == '0') {
        bitValue = 0;
    } else if (character == '1') {
        bitValue = 1;
    } else {
        return false;
    }

    hexedit::ByteEditOperation op;
    if (!hexedit::planBitEdit(currentDocumentView(), currentCursor(), currentSelection(), bitValue, op)) {
        return false;
    }
    if (!replaceEditorBytes(op.offset, op.replacement.data(), op.replacement.size(), op.replacedByteCount)) {
        return false;
    }

    clearByteSelection();
    writeBackCursor(hexedit::clampCursor(op.nextCursor, currentDocumentView(), currentViewMode()));
    return true;
}

static bool handleAsciiCharacter(unichar character)
{
    if (character > 0xff) {
        return false;
    }

    asciiAltNumpadValue = -1;
    return handleAsciiByte(static_cast<uint8_t>(character & 0xff));
}

static bool handleAsciiByte(uint8_t byteValue)
{
    hexedit::ByteEditOperation op;
    if (!hexedit::planAsciiByteEdit(currentDocumentView(), currentCursor(), currentSelection(), byteValue, op)) {
        return false;
    }

    if (!replaceEditorBytes(op.offset, op.replacement.data(), op.replacement.size(), op.replacedByteCount)) {
        return false;
    }

    clearByteSelection();
    writeBackCursor(hexedit::clampCursor(op.nextCursor, currentDocumentView(), currentViewMode()));
    return true;
}

static bool handleAsciiAltNumpadDigit(NSEvent *event)
{
    if ((event.modifierFlags & NSEventModifierFlagOption) == 0 ||
        (event.modifierFlags & NSEventModifierFlagNumericPad) == 0) {
        return false;
    }

    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length != 1) {
        return false;
    }

    const unichar character = [characters characterAtIndex:0];
    if (character < '0' || character > '9') {
        return false;
    }

    if (asciiAltNumpadValue < 0) {
        asciiAltNumpadValue = 0;
    }

    asciiAltNumpadValue = (asciiAltNumpadValue * 10) + (character - '0');
    if (asciiAltNumpadValue > 255) {
        asciiAltNumpadValue = 255;
    }

    return true;
}

static bool commitAsciiAltNumpadEntry()
{
    if (asciiAltNumpadValue < 0) {
        return false;
    }

    const uint8_t byteValue = static_cast<uint8_t>(std::clamp<NSInteger>(asciiAltNumpadValue, 0, 255));
    asciiAltNumpadValue = -1;
    return handleAsciiByte(byteValue);
}

static void showMessage(NSString *title, NSString *text)
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title;
        alert.informativeText = text;
        [alert addButtonWithTitle:L(@"button.ok")];
        [alert runModal];
    }
}

static int promptHexInteger(NSString *title, NSString *informative, int currentValue, int minValue, int maxValue)
{
    __block int result = -1;
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title;
        alert.informativeText = informative;
        [alert addButtonWithTitle:L(@"button.ok")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 24.0)];
        input.stringValue = [NSString stringWithFormat:@"%d", currentValue];
        input.alignment = NSTextAlignmentRight;
        input.accessibilityIdentifier = @"hex-editor.dialog.input";
        alert.accessoryView = input;
        [alert.window setInitialFirstResponder:input];
        [input selectText:nil];

        const NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return -1;
        }

        NSScanner *scanner = [NSScanner scannerWithString:[input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        int parsed = 0;
        if (![scanner scanInt:&parsed] || !scanner.atEnd) {
            return -2;
        }
        if (parsed < minValue || parsed > maxValue) {
            return -2;
        }
        result = parsed;
    }
    return result;
}

static void presentHexValidationError(NSString *message)
{
    showMessage(L(@"app.title"), message);
}

static NSString *promptHexGotoExpression(NSString *defaultText, std::size_t currentOffset, std::size_t totalLength)
{
    __block NSString *result = nil;
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(@"goto.title");
        // Pre-format the two hex address strings here so the localized template only sees
        // simple %@ slots — translators don't have to know about printf's "%0*zx"
        // dynamic-width syntax, and they can reorder the two values across languages.
        const int addrWidth = std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
        NSString *currentHex = [NSString stringWithFormat:g_uppercaseHex ? @"%0*zX" : @"%0*zx", addrWidth, currentOffset];
        NSString *endHex = [NSString stringWithFormat:g_uppercaseHex ? @"%0*zX" : @"%0*zx", addrWidth, totalLength];
        alert.informativeText = [NSString stringWithFormat:L(@"goto.message"), currentHex, endHex];
        [alert addButtonWithTitle:L(@"goto.button")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 220.0, 24.0)];
        input.stringValue = defaultText ?: @"";
        input.alignment = NSTextAlignmentLeft;
        input.placeholderString = L(@"goto.placeholder");
        input.accessibilityIdentifier = @"hex-editor.goto.input";
        alert.accessoryView = input;
        [alert.window setInitialFirstResponder:input];
        [input selectText:nil];

        const NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return nil;
        }
        result = [[input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    }
    return result;
}

static void gotoHexOffset(std::size_t offset)
{
    if (!hexTableView) {
        return;
    }
    if (offset > previewTotalLength) {
        offset = previewTotalLength;
    }
    activeByteOffset = offset;
    activeHexNibble = 0;
    activeCursorField = HexCursorField::Hex;
    // Goto is an unambiguous "jump the cursor here" navigation, so it collapses
    // both linear and rectangular selections — leaving a rect anchored to the
    // pre-Goto position would let the next Shift+Option+arrow extension treat
    // the new cursor as the rect's far corner, producing a wildly wrong shape.
    clearAllByteSelections();

    // Use scrollHexTableToActiveOffset() instead of a one-shot scrollRowToVisible.
    // The latter ran synchronously inside the modal-dismissal callstack, where
    // NSTableView would silently no-op when scrolling far (e.g., 64 rows up from
    // a deep cursor). Dispatching to the next runloop iteration lets the modal
    // teardown finish and the scroll lands as expected.
    scrollHexTableToActiveOffset();
    [hexTableView setNeedsDisplay:YES];
    [hexTableView.window makeFirstResponder:hexTableView];
}

static void presentHexGotoDialog()
{
    NSString *expression = promptHexGotoExpression(nil, activeByteOffset, previewTotalLength);
    if (expression == nil || expression.length == 0) {
        return;
    }

    std::size_t target = 0;
    if (!hexedit::resolveGotoOffset(std::string([expression UTF8String]),
                                     activeByteOffset,
                                     previewTotalLength,
                                     target)) {
        presentHexValidationError(L(@"goto.errorParse"));
        return;
    }
    gotoHexOffset(target);
}

// MARK: - Find / Replace

static bool executeHexFindNext(hexedit::SearchDirection direction, NSString **errorMessage)
{
    if (g_lastFindText == nil || g_lastFindText.length == 0) {
        if (errorMessage) *errorMessage = L(@"find.errorNoPriorSearch");
        return false;
    }
    hexedit::SearchPattern pattern;
    if (!hexedit::parseSearchPattern(std::string([g_lastFindText UTF8String]), g_findMatchCase, pattern)) {
        if (errorMessage) *errorMessage = L(@"find.errorParseFind");
        return false;
    }

    std::size_t startOffset = 0;
    if (direction == hexedit::SearchDirection::Forward) {
        if (hasByteSelection()) {
            startOffset = std::min(selectedByteStart + 1, hexBufferLength());
        } else {
            startOffset = std::min(activeByteOffset + 1, hexBufferLength());
        }
    } else {
        startOffset = hasByteSelection() ? selectedByteStart : activeByteOffset;
    }

    const hexedit::ByteSource &bufferSource = hexBufferSource();
    std::size_t found = 0;
    if (!hexedit::findBytePattern(bufferSource, pattern,
                                   startOffset, direction, g_findWrap, found)) {
        if (errorMessage) *errorMessage = L(@"find.errorNotFound");
        return false;
    }

    selectedByteStart = found;
    selectedByteEnd = found + pattern.bytes.size();
    activeByteOffset = found;
    activeHexNibble = 0;
    activeCursorField = HexCursorField::Hex;

    if (hexTableView) {
        const NSInteger row = static_cast<NSInteger>(found / static_cast<size_t>(currentBytesPerRow()));
        if (row >= 0 && row < hexTableView.numberOfRows) {
            [hexTableView scrollRowToVisible:row];
        }
        [hexTableView setNeedsDisplay:YES];
        if (hexStatusLabel) {
            hexStatusLabel.stringValue = makeStatusText();
        }
    }
    return true;
}

static int executeHexReplaceAll(NSString *findText, NSString *replaceText, bool matchCase, NSString **errorMessage)
{
    if (findText == nil || findText.length == 0) {
        if (errorMessage) *errorMessage = L(@"find.errorPatternEmpty");
        return -1;
    }
    if (!isPreviewBufferActive()) {
        if (errorMessage) *errorMessage = L(@"find.errorNoBuffer");
        return -1;
    }

    hexedit::SearchPattern findPattern;
    if (!hexedit::parseSearchPattern(std::string([findText UTF8String]), matchCase, findPattern)) {
        if (errorMessage) *errorMessage = L(@"find.errorParseFind");
        return -1;
    }
    hexedit::SearchPattern replacePattern;
    if (replaceText != nil && replaceText.length > 0) {
        if (!hexedit::parseSearchPattern(std::string([replaceText UTF8String]), true, replacePattern)) {
            if (errorMessage) *errorMessage = L(@"find.errorParseReplace");
            return -1;
        }
    }

    // Collect all non-overlapping match offsets, forward, no wrap.
    const hexedit::ByteSource &bufferSource = hexBufferSource();
    std::vector<std::size_t> matches;
    std::size_t cursor = 0;
    while (cursor + findPattern.bytes.size() <= hexBufferLength()) {
        std::size_t at = 0;
        if (!hexedit::findBytePattern(bufferSource, findPattern,
                                       cursor, hexedit::SearchDirection::Forward, false, at)) {
            break;
        }
        matches.push_back(at);
        cursor = at + findPattern.bytes.size();
    }

    if (matches.empty()) {
        return 0;
    }

    NppHandle editor = previewScintillaHandle;
    if (!editor) {
        if (errorMessage) *errorMessage = L(@"find.errorNoEditor");
        return -1;
    }

    suppressModificationRefresh = true;
    sci(editor, SCI_BEGINUNDOACTION);
    // Apply in reverse so earlier offsets stay valid as we mutate from the tail forward.
    for (auto it = matches.rbegin(); it != matches.rend(); ++it) {
        const std::size_t off = *it;
        sci(editor, SCI_SETTARGETSTART, off, 0);
        sci(editor, SCI_SETTARGETEND, off + findPattern.bytes.size(), 0);
        sci(editor, SCI_REPLACETARGET, replacePattern.bytes.size(),
            reinterpret_cast<intptr_t>(replacePattern.bytes.data()));
    }
    sci(editor, SCI_ENDUNDOACTION);
    suppressModificationRefresh = false;

    bindHexBufferToActiveScintilla();
    clampActiveCursor();
    clearByteSelection();
    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }
    if (hexStatusLabel) {
        hexStatusLabel.stringValue = makeStatusText();
    }
    return static_cast<int>(matches.size());
}

static bool executeHexReplaceCurrentSelection(NSString *findText, NSString *replaceText, bool matchCase, NSString **errorMessage)
{
    if (!hasByteSelection()) {
        if (errorMessage) *errorMessage = L(@"find.errorReplaceCurrent");
        return false;
    }
    hexedit::SearchPattern findPattern;
    if (findText == nil || !hexedit::parseSearchPattern(std::string([findText UTF8String]), matchCase, findPattern)) {
        if (errorMessage) *errorMessage = L(@"find.errorParseFind");
        return false;
    }
    hexedit::SearchPattern replacePattern;
    if (replaceText != nil && replaceText.length > 0) {
        if (!hexedit::parseSearchPattern(std::string([replaceText UTF8String]), true, replacePattern)) {
            if (errorMessage) *errorMessage = L(@"find.errorParseReplace");
            return false;
        }
    }

    const std::size_t selLen = selectedByteEnd - selectedByteStart;
    if (selLen != findPattern.bytes.size()) {
        if (errorMessage) *errorMessage = L(@"find.errorReplaceLength");
        return false;
    }

    if (!applyEditorByteTransaction(selectedByteStart,
                                     replacePattern.bytes.empty() ? nullptr : replacePattern.bytes.data(),
                                     replacePattern.bytes.size(), selLen)) {
        if (errorMessage) *errorMessage = L(@"find.errorReplaceFailedShort");
        return false;
    }

    activeByteOffset = std::min(selectedByteStart + replacePattern.bytes.size(), hexBufferLength());
    activeHexNibble = 0;
    activeCursorField = HexCursorField::Hex;
    clearByteSelection();
    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }
    return true;
}

static void presentHexFindDialog(BOOL replaceMode)
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = replaceMode ? L(@"find.titleReplace") : L(@"find.titleFind");
        alert.informativeText = L(@"find.message");
        [alert addButtonWithTitle:L(@"find.button.findNext")];
        if (replaceMode) {
            [alert addButtonWithTitle:L(@"find.button.replaceAll")];
        }
        [alert addButtonWithTitle:L(@"button.cancel")];

        const CGFloat width = 360.0;
        const CGFloat fieldHeight = 22.0;
        const CGFloat checkHeight = 18.0;
        const CGFloat verticalGap = 6.0;
        const int rows = replaceMode ? 5 : 4;
        const CGFloat totalHeight = (fieldHeight * 2) + (checkHeight * 2) + (verticalGap * (rows - 1));
        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

        CGFloat y = totalHeight - fieldHeight;
        NSTextField *findField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, y, width, fieldHeight)];
        findField.placeholderString = L(@"find.placeholder.find");
        findField.stringValue = g_lastFindText ?: @"";
        findField.accessibilityIdentifier = @"hex-editor.find.input";
        [accessory addSubview:findField];

        NSTextField *replaceField = nil;
        if (replaceMode) {
            y -= (fieldHeight + verticalGap);
            replaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, y, width, fieldHeight)];
            replaceField.placeholderString = L(@"find.placeholder.replace");
            replaceField.stringValue = g_lastReplaceText ?: @"";
            replaceField.accessibilityIdentifier = @"hex-editor.replace.input";
            [accessory addSubview:replaceField];
        }

        y -= (checkHeight + verticalGap);
        NSButton *matchCaseButton = [NSButton checkboxWithTitle:L(@"find.toggle.matchCase") target:nil action:nil];
        matchCaseButton.frame = NSMakeRect(0, y, width, checkHeight);
        matchCaseButton.state = g_findMatchCase ? NSControlStateValueOn : NSControlStateValueOff;
        matchCaseButton.accessibilityIdentifier = @"hex-editor.find.matchcase";
        [accessory addSubview:matchCaseButton];

        y -= (checkHeight + verticalGap);
        NSButton *wrapButton = [NSButton checkboxWithTitle:L(@"find.toggle.wrap") target:nil action:nil];
        wrapButton.frame = NSMakeRect(0, y, width, checkHeight);
        wrapButton.state = g_findWrap ? NSControlStateValueOn : NSControlStateValueOff;
        wrapButton.accessibilityIdentifier = @"hex-editor.find.wrap";
        [accessory addSubview:wrapButton];

        alert.accessoryView = accessory;
        [alert.window setInitialFirstResponder:findField];
        [findField selectText:nil];

        const NSModalResponse response = [alert runModal];
        // Persist whatever the user typed regardless of which action they took.
        g_lastFindText = [findField.stringValue copy] ?: @"";
        if (replaceField) {
            g_lastReplaceText = [replaceField.stringValue copy] ?: @"";
        }
        g_findMatchCase = matchCaseButton.state == NSControlStateValueOn;
        g_findWrap = wrapButton.state == NSControlStateValueOn;
        hexPrefSetBool(HEX_PREF_FIND_MATCH_CASE, g_findMatchCase);
        hexPrefSetBool(HEX_PREF_FIND_WRAP, g_findWrap);

        if (response == NSAlertFirstButtonReturn) {
            // Find Next
            NSString *err = nil;
            if (!executeHexFindNext(hexedit::SearchDirection::Forward, &err)) {
                presentHexValidationError(err ?: L(@"find.errorNotFound"));
            }
        } else if (replaceMode && response == NSAlertSecondButtonReturn) {
            // Replace All
            NSString *err = nil;
            const int count = executeHexReplaceAll(g_lastFindText, g_lastReplaceText, g_findMatchCase, &err);
            if (count < 0) {
                presentHexValidationError(err ?: L(@"find.errorReplaceFailed"));
            } else {
                NSString *message = (count == 1)
                    ? L(@"find.replacedSingular")
                    : [NSString stringWithFormat:L(@"find.replacedPlural"), count];
                showMessage(L(@"app.title"), message);
            }
        }
        // Third button (Cancel) — do nothing.
    }
}

// MARK: - Compare HEX

static bool compareDiffMaskCellHasDiff(NSInteger row, NSInteger cellIndex)
{
    if (g_compareDiffs.empty() || row < 0 || cellIndex < 0) {
        return false;
    }
    const std::size_t bpr = static_cast<std::size_t>(currentBytesPerRow());
    const int bpc = std::max(g_bytesPerCell, 1);
    const std::size_t firstByte = static_cast<std::size_t>(row) * bpr + static_cast<std::size_t>(cellIndex) * static_cast<std::size_t>(bpc);
    for (int i = 0; i < bpc; ++i) {
        const std::size_t off = firstByte + static_cast<std::size_t>(i);
        if (off < g_compareDiffs.size() && g_compareDiffs[off]) {
            return true;
        }
    }
    return false;
}

static int executeHexCompareWithFile(NSString *otherFilePath, NSString **errorMessage)
{
    if (!isPreviewBufferActive()) {
        if (errorMessage) *errorMessage = L(@"compare.openHexFirstRun");
        return -1;
    }
    if (otherFilePath == nil || otherFilePath.length == 0) {
        if (errorMessage) *errorMessage = L(@"compare.errorNoFile");
        return -1;
    }

    NSError *readError = nil;
    NSData *otherData = [NSData dataWithContentsOfFile:otherFilePath
                                                options:NSDataReadingMappedIfSafe
                                                  error:&readError];
    if (otherData == nil) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:L(@"compare.errorReadFile"),
                otherFilePath, readError.localizedDescription ?: L(@"compare.errorReadUnknown")];
        }
        return -1;
    }

    const std::uint8_t *otherBytes = static_cast<const std::uint8_t *>(otherData.bytes);
    const std::size_t otherLen = otherData.length;

    hexedit::SpanByteSource otherSource(otherBytes, otherLen);
    g_compareDiffs = hexedit::computeByteDiffs(hexBufferSource(), otherSource);
    g_compareOtherPath = [otherFilePath copy];

    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }

    if (g_compareDiffs.empty()) {
        return 0;  // identical
    }
    int diffCount = 0;
    for (bool b : g_compareDiffs) {
        if (b) ++diffCount;
    }
    return diffCount;
}

static void clearHexCompareResult()
{
    if (g_compareDiffs.empty() && g_compareOtherPath == nil) {
        return;
    }
    g_compareDiffs.clear();
    g_compareOtherPath = nil;
    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }
}

static void presentHexCompareDialog()
{
    if (!isPreviewBufferActive()) {
        showMessage(L(@"app.title"), L(@"compare.openHexFirstCompare"));
        return;
    }

    @autoreleasepool {
        // Test hook: --test-compare-with=<path> bypasses the file picker. Lets the XCTest
        // harness drive Compare without trying to automate NSOpenPanel.
        NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
        NSString *fixturePath = nil;
        for (NSString *arg in args) {
            if ([arg hasPrefix:@"--test-compare-with="]) {
                fixturePath = [arg substringFromIndex:[@"--test-compare-with=" length]];
                break;
            }
        }

        NSString *chosenPath = fixturePath;
        if (chosenPath == nil) {
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.title = L(@"compare.openPanelTitle");
            panel.message = L(@"compare.openPanelMessage");
            panel.canChooseFiles = YES;
            panel.canChooseDirectories = NO;
            panel.allowsMultipleSelection = NO;
            panel.resolvesAliases = YES;
            if ([panel runModal] != NSModalResponseOK) {
                return;
            }
            chosenPath = panel.URL.path;
        }

        NSString *err = nil;
        const int result = executeHexCompareWithFile(chosenPath, &err);
        if (result < 0) {
            presentHexValidationError(err ?: L(@"compare.errorFailed"));
            return;
        }
        if (result == 0) {
            showMessage(L(@"app.titleCompare"), L(@"compare.summaryMatch"));
        } else {
            NSString *summary = (result == 1)
                ? L(@"compare.summaryDifferSingular")
                : [NSString stringWithFormat:L(@"compare.summaryDifferPlural"), result];
            showMessage(L(@"app.titleCompare"), summary);
        }
    }
}

// MARK: - Insert Columns

static int executeInsertColumns(NSString *patternText, int count, int position, NSString **errorMessage)
{
    if (!isPreviewBufferActive()) {
        if (errorMessage) *errorMessage = L(@"find.errorNoBuffer");
        return -1;
    }
    if (patternText == nil || patternText.length == 0) {
        if (errorMessage) *errorMessage = L(@"insertColumns.errorEmptyPattern");
        return -1;
    }

    // Parse pattern as hex bytes (the Windows dialog accepted hex input only).
    std::vector<std::uint8_t> patternBytes;
    if (!hexedit::parseHexClipboardText(std::string([patternText UTF8String]), patternBytes) || patternBytes.empty()) {
        if (errorMessage) *errorMessage = L(@"insertColumns.errorParsePattern");
        return -1;
    }

    const int bpc = std::max(g_bytesPerCell, 1);
    const int currentColumns = std::max(g_columns, 1);
    const int columnsLimit = columnsLimitForBytesPerCell(bpc);
    if (count <= 0 || (count + currentColumns) > columnsLimit) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:L(@"insertColumns.errorRangeCount"),
            std::max(0, columnsLimit - currentColumns)];
        return -1;
    }
    if (position < 0 || position > currentColumns) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:L(@"insertColumns.errorRangePosition"),
            currentColumns];
        return -1;
    }

    NppHandle editor = previewScintillaHandle;
    if (!editor) {
        if (errorMessage) *errorMessage = L(@"find.errorNoEditor");
        return -1;
    }

    // Build the per-row payload: `count * bpc` bytes drawn from the pattern, repeating
    // (cycling through pattern.bytes). Mirrors Windows insertColumns which fills enough
    // pattern repetitions to land on the count*bits boundary.
    const std::size_t bytesPerRowInsert = static_cast<std::size_t>(count) * static_cast<std::size_t>(bpc);
    std::vector<std::uint8_t> rowPayload(bytesPerRowInsert);
    for (std::size_t i = 0; i < bytesPerRowInsert; ++i) {
        rowPayload[i] = patternBytes[i % patternBytes.size()];
    }

    // Compute insertion offsets per row in the *original* document. Apply from the last
    // row to the first so earlier offsets don't shift as we mutate the tail.
    const std::size_t bpr = static_cast<std::size_t>(currentBytesPerRow());
    if (bpr == 0) {
        if (errorMessage) *errorMessage = L(@"insertColumns.errorRowSize");
        return -1;
    }
    const std::size_t totalLength = hexBufferLength();
    // Number of rows to insert into is the number of fully-populated rows. A trailing
    // partial row gets padding inserted up to the position too — match Windows which
    // iterates HEXM_GETLINECNT, the count of rendered rows including the trailing one.
    const std::size_t fullRows = totalLength / bpr;
    const bool hasPartial = (totalLength % bpr) != 0;
    const std::size_t totalRows = fullRows + (hasPartial ? 1 : 0);
    if (totalRows == 0) {
        if (errorMessage) *errorMessage = L(@"insertColumns.errorBufferEmpty");
        return -1;
    }

    const std::size_t insertOffsetWithinRow = static_cast<std::size_t>(position) * static_cast<std::size_t>(bpc);

    suppressModificationRefresh = true;
    sci(editor, SCI_BEGINUNDOACTION);
    for (std::size_t i = totalRows; i-- > 0; ) {
        const std::size_t rowStart = i * bpr;
        const std::size_t insertionOffset = std::min(rowStart + insertOffsetWithinRow, totalLength);
        sci(editor, SCI_SETTARGETSTART, insertionOffset, 0);
        sci(editor, SCI_SETTARGETEND, insertionOffset, 0);
        sci(editor, SCI_REPLACETARGET, rowPayload.size(), reinterpret_cast<intptr_t>(rowPayload.data()));
    }
    sci(editor, SCI_ENDUNDOACTION);
    suppressModificationRefresh = false;

    // Grow the visible column count so the new bytes line up where the user asked.
    g_columns = currentColumns + count;
    saveHexPrefs();

    bindHexBufferToActiveScintilla();
    clampActiveCursor();
    clearByteSelection();
    applyHexViewMode();
    return static_cast<int>(totalRows);
}

static void presentInsertColumnsDialog()
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(@"insertColumns.title");
        alert.informativeText = [NSString stringWithFormat:L(@"insertColumns.message"),
            g_bytesPerCell,
            std::max(0, columnsLimitForBytesPerCell(g_bytesPerCell) - g_columns),
            g_bytesPerCell * 8,
            g_columns];
        [alert addButtonWithTitle:L(@"insertColumns.button")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        const CGFloat width = 320.0;
        const CGFloat fieldHeight = 22.0;
        const CGFloat verticalGap = 6.0;
        const CGFloat totalHeight = fieldHeight * 3 + verticalGap * 2;
        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

        CGFloat y = totalHeight - fieldHeight;
        NSTextField *patternField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, y, width, fieldHeight)];
        patternField.placeholderString = L(@"insertColumns.placeholder.pattern");
        patternField.accessibilityIdentifier = @"hex-editor.insertcolumns.pattern";
        [accessory addSubview:patternField];

        y -= (fieldHeight + verticalGap);
        NSTextField *countField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, y, width, fieldHeight)];
        countField.placeholderString = L(@"insertColumns.placeholder.count");
        countField.alignment = NSTextAlignmentRight;
        countField.accessibilityIdentifier = @"hex-editor.insertcolumns.count";
        [accessory addSubview:countField];

        y -= (fieldHeight + verticalGap);
        NSTextField *positionField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, y, width, fieldHeight)];
        positionField.stringValue = @"0";
        positionField.placeholderString = L(@"insertColumns.placeholder.position");
        positionField.alignment = NSTextAlignmentRight;
        positionField.accessibilityIdentifier = @"hex-editor.insertcolumns.position";
        [accessory addSubview:positionField];

        alert.accessoryView = accessory;
        [alert.window setInitialFirstResponder:patternField];
        [patternField selectText:nil];

        const NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return;
        }

        NSString *pattern = [patternField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        const int countValue = countField.intValue;
        const int positionValue = positionField.intValue;

        NSString *err = nil;
        const int rows = executeInsertColumns(pattern, countValue, positionValue, &err);
        if (rows < 0) {
            presentHexValidationError(err ?: L(@"insertColumns.errorFailed"));
            return;
        }
        // The summary mentions both column-count plurality and row-count plurality. We use a
        // simple two-message split rather than ICU plural forms so translators can rephrase
        // each form independently.
        NSString *summary = (rows == 1)
            ? [NSString stringWithFormat:L(@"insertColumns.summarySingularRows"),
                countValue, countValue == 1 ? @"" : @"s"]
            : [NSString stringWithFormat:L(@"insertColumns.summaryPluralRows"),
                countValue, countValue == 1 ? @"" : @"s", rows];
        showMessage(L(@"app.title"), summary);
    }
}

// MARK: - Pattern Replace

static int executePatternReplace(NSString *patternText, NSString **errorMessage)
{
    if (!isPreviewBufferActive()) {
        if (errorMessage) *errorMessage = L(@"patternReplace.openHexFirst");
        return -1;
    }
    if (!hasAnyByteSelection()) {
        if (errorMessage) *errorMessage = L(@"patternReplace.requireSelection");
        return -1;
    }
    if (patternText == nil || patternText.length == 0) {
        if (errorMessage) *errorMessage = L(@"patternReplace.errorEmptyPattern");
        return -1;
    }

    std::vector<std::uint8_t> patternBytes;
    if (!hexedit::parseHexClipboardText(std::string([patternText UTF8String]), patternBytes) || patternBytes.empty()) {
        if (errorMessage) *errorMessage = L(@"patternReplace.errorParsePattern");
        return -1;
    }

    if (hasRectSelection()) {
        // Rectangular fill: each row starts fresh from pattern[0]. Build a row-major
        // (width × height) buffer whose row r col c = pattern[c % pattern.size()],
        // then use applyRectBytesPaste — same per-row clipping it already does for
        // paste so a rect overhanging EOF fills only the in-file rows / columns.
        std::vector<std::uint8_t> filler(g_rectSelection.totalBytes());
        for (std::size_t r = 0; r < g_rectSelection.height; ++r) {
            for (std::size_t c = 0; c < g_rectSelection.width; ++c) {
                filler[r * g_rectSelection.width + c] = patternBytes[c % patternBytes.size()];
            }
        }
        // Compute the actual number of bytes that will be written (clipped at EOF).
        std::size_t bytesWritten = 0;
        for (const auto &range : hexedit::rectToRanges(g_rectSelection, previewTotalLength)) {
            bytesWritten += range.byteCount;
        }
        if (!applyRectBytesPaste(g_rectSelection, filler.data(), filler.size())) {
            if (errorMessage) *errorMessage = L(@"patternReplace.errorFailed");
            return -1;
        }
        // Leave the rect selected so the user can repeat (matches Paste behaviour).
        if (hexTableView) {
            [hexTableView setNeedsDisplay:YES];
        }
        return static_cast<int>(bytesWritten);
    }

    const std::size_t length = selectedByteEnd - selectedByteStart;
    std::vector<std::uint8_t> filler(length);
    for (std::size_t i = 0; i < length; ++i) {
        filler[i] = patternBytes[i % patternBytes.size()];
    }

    if (!applyEditorByteTransaction(selectedByteStart, filler.data(), filler.size(), length)) {
        if (errorMessage) *errorMessage = L(@"patternReplace.errorFailed");
        return -1;
    }

    activeByteOffset = std::min(selectedByteStart + length, previewTotalLength);
    activeHexNibble = 0;
    activeCursorField = HexCursorField::Hex;
    clearByteSelection();
    if (hexTableView) {
        [hexTableView reloadData];
        [hexTableView setNeedsDisplay:YES];
    }
    return static_cast<int>(length);
}

static void presentPatternReplaceDialog()
{
    if (!isPreviewBufferActive()) {
        showMessage(L(@"app.title"), L(@"patternReplace.openHexFirst"));
        return;
    }
    if (!hasAnyByteSelection()) {
        showMessage(L(@"app.title"), L(@"patternReplace.requireSelection"));
        return;
    }

    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(@"patternReplace.title");
        if (hasRectSelection()) {
            // Rect-specific message — explains the per-row restart so the user knows
            // the pattern won't run continuously across rows like the linear path.
            alert.informativeText = [NSString stringWithFormat:L(@"patternReplace.messageRect"),
                (unsigned long)g_rectSelection.width,
                (unsigned long)g_rectSelection.height];
        } else {
            const std::size_t length = selectedByteEnd - selectedByteStart;
            alert.informativeText = [NSString stringWithFormat:L(@"patternReplace.message"), length];
        }
        [alert addButtonWithTitle:L(@"patternReplace.button")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        NSTextField *patternField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        patternField.placeholderString = L(@"patternReplace.placeholder");
        patternField.accessibilityIdentifier = @"hex-editor.patternreplace.pattern";
        alert.accessoryView = patternField;
        [alert.window setInitialFirstResponder:patternField];

        // Capture rect shape before runModal — executePatternReplace leaves the
        // selection in place but we still want the summary to mention the original
        // dimensions even if a future change shifts that.
        const bool wasRect = hasRectSelection();
        const std::size_t rectW = g_rectSelection.width;
        const std::size_t rectH = g_rectSelection.height;

        const NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return;
        }

        NSString *pattern = [patternField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *err = nil;
        const int bytesWritten = executePatternReplace(pattern, &err);
        if (bytesWritten < 0) {
            presentHexValidationError(err ?: L(@"patternReplace.errorFailed"));
            return;
        }
        NSString *summary = nil;
        if (wasRect) {
            summary = [NSString stringWithFormat:L(@"patternReplace.summaryRect"),
                (unsigned long)rectW,
                (unsigned long)rectH,
                (unsigned long)bytesWritten];
        } else if (bytesWritten == 1) {
            summary = L(@"patternReplace.summarySingular");
        } else {
            summary = [NSString stringWithFormat:L(@"patternReplace.summaryPlural"), bytesWritten];
        }
        showMessage(L(@"app.title"), summary);
    }
}

// Vertically-center the cell text. Default NSTextFieldCell anchors the
// glyphs near the top of the cell rect, so the row's extra padding (the
// `+4` in rowHeight) all ends up *below* the text — looks lopsided when
// the row highlight or selection wash extends to row edges. Centering
// splits that padding evenly above and below the glyph baseline.
@interface HexCenteredTextCell : NSTextFieldCell
@end
@implementation HexCenteredTextCell
- (NSRect)drawingRectForBounds:(NSRect)theRect
{
    NSRect r = [super drawingRectForBounds:theRect];
    const NSSize textSize = [self cellSizeForBounds:theRect];
    const CGFloat extraVertical = r.size.height - textSize.height;
    if (extraVertical > 0) {
        // NSTableView is flipped (origin top-left). Pushing origin.y down
        // by half the slack moves the glyphs toward the row's vertical
        // midline; trimming size.height by the same amount keeps the
        // bottom edge stable.
        r.origin.y += floor(extraVertical / 2.0);
        r.size.height -= extraVertical;
    }
    return r;
}
@end

// NSTableView's cell-based AX traversal honors the legacy informal-protocol
// method `accessibilityIsIgnored` (NSAccessibility), not the newer
// setAccessibilityElement:. Override both for belt-and-suspenders coverage so
// these spacer cells don't appear as indexable static texts in XCUI.
@interface HexSpacerCell : HexCenteredTextCell
@end
@implementation HexSpacerCell
- (BOOL)accessibilityIsIgnored { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityUnknownRole; }
@end

static void configureTableColumn(NSTableView *tableView, NSString *identifier, NSString *title, CGFloat width, NSFont *font)
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = width;
    column.resizingMask = NSTableColumnNoResizing;

    const NSTextAlignment alignment = [identifier hasPrefix:@"cell"] ? NSTextAlignmentCenter : NSTextAlignmentLeft;

    // Spacer columns ("offsetSpacer" between address and bytes, "spacer" between
    // bytes and ASCII) are pure visual gutters with empty values. Use the
    // AX-ignored cell subclass so they don't become indexable static texts —
    // this keeps `row.staticTexts.element(boundBy:N)` mapped to byte N-1
    // uniformly across the row, regardless of how many spacer columns we add.
    const BOOL isSpacer = [identifier isEqualToString:@"offsetSpacer"] || [identifier isEqualToString:@"spacer"];
    NSTextFieldCell *cell = isSpacer ? [[HexSpacerCell alloc] init] : [[HexCenteredTextCell alloc] init];
    cell.font = font;
    cell.lineBreakMode = NSLineBreakByClipping;
    cell.alignment = alignment;
    column.dataCell = cell;

    // Match the header's alignment to the data cell's so the column index ("00", "01",
    // ...) sits visually centered above the centered byte values, and "Offset" / "ASCII"
    // stay left-aligned over their left-aligned data.
    //
    // We set alignment via TWO mechanisms because each plays a different role:
    //
    //   - `headerCell.alignment` — semantic property. Reported by the AX
    //     diagnostic (`hdrAlignMatch`) and observable by anything that reads
    //     the cell's intended alignment. NSTableHeaderCell *renders* the title
    //     buggily when this property is non-left (clips to a horizontal sliver
    //     of pixels that looks like "_"), but the property itself is fine to
    //     set and read back.
    //
    //   - `headerCell.attributedStringValue` with NSParagraphStyle.alignment —
    //     drives the actual draw. AppKit honors the paragraph attributes when
    //     rendering attributed-string-based titles, bypassing the buggy
    //     alignment-property code path. This is what produces the correctly
    //     drawn centered "00" / "0f" headers.
    //
    // Setting only one fails: alignment-only renders as dashes; attributed-only
    // leaves the cell's alignment property as the default left, breaking the
    // hdrAlignMatch assertion.
    column.headerCell.alignment = alignment;
    NSMutableParagraphStyle *headerParagraph = [[NSMutableParagraphStyle defaultParagraphStyle] mutableCopy];
    headerParagraph.alignment = alignment;
    headerParagraph.lineBreakMode = NSLineBreakByClipping;
    NSFont *headerFont = hexHeaderFontFor(font);
    column.headerCell.font = headerFont;
    column.headerCell.attributedStringValue = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{
                NSFontAttributeName: headerFont,
                NSParagraphStyleAttributeName: headerParagraph,
            }];

    [tableView addTableColumn:column];
}

static void addHexCellColumns(NSTableView *table, NSFont *font)
{
    const hexedit::ViewMode mode = currentViewMode();
    const int cells = std::max(currentCellsPerRow(), 1);
    const CGFloat cellWidth = cellColumnWidth(font, mode);

    configureTableColumn(table, @"offset", L(@"table.header.offset"), offsetColumnWidth(font), font);
    // Empty spacer column between offset and the first hex byte. Real column
    // (not padding inside offset) so the visible gap is reflected in the AX
    // frame geometry the spacing test asserts on. AX-hidden inside
    // configureTableColumn so this column does not become an indexable
    // staticTexts entry — keeps `boundBy:N = byte N-1` for tests.
    configureTableColumn(table, @"offsetSpacer", @"", offsetTrailingPadding(font), font);
    for (int column = 0; column < cells; ++column) {
        const std::size_t firstByte = static_cast<std::size_t>(column) * static_cast<std::size_t>(g_bytesPerCell);
        configureTableColumn(
            table,
            [NSString stringWithFormat:@"cell%02d", column],
            [NSString stringWithFormat:g_uppercaseHex ? @"%02zX" : @"%02zx", firstByte],
            cellWidth,
            font);
    }
    configureTableColumn(table, @"spacer", @"", asciiSeparatorWidth(font), font);
    configureTableColumn(table, @"ascii", L(@"table.header.ascii"), asciiColumnWidth(font), font);
}

static void applyHexViewMode()
{
    if (!hexTableView) {
        return;
    }
    NSPoint scrollOrigin = NSZeroPoint;
    if (hexTableView.enclosingScrollView) {
        scrollOrigin = hexTableView.enclosingScrollView.contentView.bounds.origin;
    }

    NSArray<NSTableColumn *> *existing = [hexTableView.tableColumns copy];
    for (NSTableColumn *column in existing) {
        [hexTableView removeTableColumn:column];
    }
    addHexCellColumns(hexTableView, hexTableFont());
    applyHexTableLayout(hexTableView, hexStatusLabel);
    [hexTableView reloadData];
    if (hexTableView.enclosingScrollView) {
        [hexTableView.enclosingScrollView.contentView scrollToPoint:scrollOrigin];
        [hexTableView.enclosingScrollView reflectScrolledClipView:hexTableView.enclosingScrollView.contentView];
    }
    [hexTableView setNeedsDisplay:YES];
}

static void setHexViewBytesPerCell(int bytesPerCell)
{
    if (!hexedit::isValidBytesPerCell(bytesPerCell)) {
        return;
    }
    if (g_bytesPerCell == bytesPerCell) {
        return;
    }
    g_bytesPerCell = bytesPerCell;
    // Don't reset g_littleEndian when dropping to 1-byte cells: the
    // setting is benign at bpc=1 (formatCell only honours littleEndian
    // for bpc > 1) and the user's preference should survive a temporary
    // switch to 8-bit. Earlier behaviour reset the flag to mirror the
    // Windows plugin's isLittle reset on HEX_BYTE; we deliberately
    // diverge so the preference is persistent across column-width
    // changes — this is what the user sees in the Options dialog.
    g_columns = defaultColumnsForBytesPerCell(g_bytesPerCell);
    // Rect geometry is anchored to the row width; that width just changed.
    clearRectSelection();
    saveHexPrefs();
    applyHexViewMode();
}

static void toggleHexViewBinary()
{
    g_notation = (g_notation == hexedit::CellNotation::Binary)
        ? hexedit::CellNotation::Hex
        : hexedit::CellNotation::Binary;
    saveHexPrefs();
    // Cursor.nibble carries different ranges per mode (0-1 hex, 0-7 binary). Switching
    // back to hex while the caret is mid-byte (e.g. bit 5) would leave it in the wrong
    // range and the hex digit planner would misroute the next typed character.
    clampActiveCursor();
    applyHexViewMode();
}

static void toggleHexViewEndian()
{
    if (g_bytesPerCell <= 1) {
        return;
    }
    g_littleEndian = !g_littleEndian;
    saveHexPrefs();
    applyHexViewMode();
}

static void setHexAddressWidth(int width)
{
    const int clamped = std::clamp(width, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
    if (clamped == g_addressWidth) {
        return;
    }
    g_addressWidth = clamped;
    saveHexPrefs();
    applyHexViewMode();
}

static void setHexColumns(int columns)
{
    const int limit = columnsLimitForBytesPerCell(g_bytesPerCell);
    const int clamped = std::clamp(columns, 1, limit);
    if (clamped == g_columns) {
        return;
    }
    g_columns = clamped;
    // Rect geometry is anchored to the row width; that width just changed.
    clearRectSelection();
    saveHexPrefs();
    applyHexViewMode();
}

// Frame height that fully contains a font's ascender + descender extent, plus
// generous vertical padding. NSTextField with a frame shorter than the font's
// natural line-height clips descenders ('y', 'g', 'p') at the bottom — so any
// label that displays Latin text must be sized via this helper, not by hardcoded
// point values that work for one font size and silently break at others.
static CGFloat textFrameHeightForFont(NSFont *font)
{
    if (font == nil) {
        return 16.0;
    }
    // descender is negative for most fonts. ascender - descender = full glyph
    // extent. +6 for top/bottom padding so glyphs don't kiss the frame edge.
    return ceil(font.ascender - font.descender + 6.0);
}

// Font used for the row above the column-header bar that reports buffer size.
// Sized 2 points smaller than the hex grid font so the status row reads as
// secondary chrome, with a 9pt floor below which Latin glyphs become unreadable.
static NSFont *statusLabelFontFor(NSFont *gridFont)
{
    return [NSFont systemFontOfSize:std::max<CGFloat>(gridFont.pointSize - 2.0, 9.0)];
}

// Header font tracks the cell font so column titles (`00 01 02…`) scale
// proportionately with the cells beneath them under zoom (Cmd+/Cmd-/pinch).
// Sized 2 points smaller for visual hierarchy — matches the existing
// status-label pattern. 9pt floor for legibility at minimum zoom.
static NSFont *hexHeaderFontFor(NSFont *gridFont)
{
    return [NSFont systemFontOfSize:std::max<CGFloat>(gridFont.pointSize - 2.0, 9.0)];
}

static void applyHexTableLayout(NSTableView *table, NSTextField *statusLabel)
{
    if (!table) {
        return;
    }

    NSFont *font = hexTableFont();
    table.rowHeight = std::max<CGFloat>(ceil(font.ascender - font.descender + 4.0), 14.0);
    table.intercellSpacing = NSMakeSize(0.0, 1.0);

    const hexedit::ViewMode mode = currentViewMode();
    const CGFloat cellWidth = cellColumnWidth(font, mode);
    NSFont *headerFont = hexHeaderFontFor(font);
    for (NSTableColumn *column in table.tableColumns) {
        NSString *identifier = column.identifier;
        CGFloat width = 0.0;

        if ([identifier isEqualToString:@"offset"]) {
            width = offsetColumnWidth(font);
        } else if ([identifier isEqualToString:@"ascii"]) {
            width = asciiColumnWidth(font);
        } else if ([identifier isEqualToString:@"offsetSpacer"]) {
            width = offsetTrailingPadding(font);
        } else if ([identifier isEqualToString:@"spacer"]) {
            width = asciiSeparatorWidth(font);
        } else {
            width = cellWidth;
        }

        column.width = width;
        column.minWidth = width;
        NSTextFieldCell *cell = static_cast<NSTextFieldCell *>(column.dataCell);
        cell.font = font;

        // Refresh header font + attributed title so the column-index headers
        // (`00 01 02 …` and `Offset` / `ASCII`) scale with the cell font
        // under zoom. Mutate the existing headerCell rather than replacing
        // it: replacing column.headerCell during AppKit's draw cycle (which
        // can call into this layout via setNeedsDisplay → live-resize
        // chains) leaves the header view holding a freed pointer mid-draw
        // and crashes NPP under XCUITest's rapid menu interactions.
        const NSTextAlignment alignment = column.headerCell.alignment;
        NSMutableParagraphStyle *headerParagraph = [[NSMutableParagraphStyle defaultParagraphStyle] mutableCopy];
        headerParagraph.alignment = alignment;
        headerParagraph.lineBreakMode = NSLineBreakByClipping;
        column.headerCell.font = headerFont;
        column.headerCell.attributedStringValue = [[NSAttributedString alloc]
            initWithString:(column.title ?: @"")
                attributes:@{
                    NSFontAttributeName: headerFont,
                    NSParagraphStyleAttributeName: headerParagraph,
                }];
    }
    // Header row height tracks the scaled header font's metrics so big-zoom
    // headers don't clip vertically. Note that the visual width of the
    // header's background fill is constrained to the column span — see
    // HexTableHeaderView's drawRect: — so growing the row height doesn't
    // expose the empty area to the right of the ASCII pane.
    if (NSTableHeaderView *headerView = table.headerView) {
        const CGFloat headerRowHeight = ceil(headerFont.ascender - headerFont.descender + 6.0);
        NSRect frame = headerView.frame;
        frame.size.height = std::max(headerRowHeight, 17.0);
        headerView.frame = frame;
        [headerView setNeedsDisplay:YES];
    }

    if (statusLabel) {
        NSFont *labelFont = statusLabelFontFor(hexTableFont());
        statusLabel.font = labelFont;

        NSView *rootView = statusLabel.superview;
        if (rootView) {
            // Use the rootView's *actual* size (set by NPP based on the editor
            // view dimensions), not HEX_TABLE_HEIGHT — that constant is only
            // valid when the host's editor area happens to be 640pt tall. When
            // NPP allocates a taller editor (e.g. 688pt), the old code positioned
            // the status label at y=619 (HEX_TABLE_HEIGHT-based), leaving a dark
            // band of empty space above the status, between the host's tab bar
            // and our hex view's top.
            const CGFloat rootHeight = NSHeight(rootView.frame);
            const CGFloat rootWidth = NSWidth(rootView.frame);

            // Status row height tracks the font's full ascender+descender extent,
            // plus a 4 pt margin above the row, so descender glyphs never clip.
            // The reserved status area is labelHeight + topMargin; the scroll view
            // gets whatever remains below it.
            const CGFloat labelHeight = textFrameHeightForFont(labelFont);
            const CGFloat topMargin = 4.0;
            const CGFloat statusAreaHeight = labelHeight + topMargin;
            statusLabel.frame = NSMakeRect(8, rootHeight - topMargin - labelHeight,
                                           rootWidth - 16, labelHeight);
            table.enclosingScrollView.frame = NSMakeRect(0, 0, rootWidth,
                                                         rootHeight - statusAreaHeight);
        }
    }
}

static NSView *createHexTableView(NSTableView **tableView, NSTextField **statusLabel)
{
    NSFont *font = hexTableFont();
    const CGFloat tableWidth = tableContainerWidth(font);
    NSView *rootView = [[HexTableContainerView alloc] initWithFrame:NSMakeRect(0, 0, tableWidth, HEX_TABLE_HEIGHT)];
    rootView.accessibilityIdentifier = kHexEditorRootAccessibilityID;
    // Without autoresizing, the rootView stays a fixed 640pt tall regardless
    // of the dock-panel space NPP allocates around it — when NPP gives more
    // vertical room, the difference shows up as a dark band above (or below)
    // the rootView. Subviews (status label sticks to top via MinYMargin, scroll
    // view fills the rest via HeightSizable) already adapt; the rootView itself
    // just needs the same flexibility to inherit the parent's actual size.
    rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *label = [NSTextField labelWithString:@""];
    NSFont *labelFont = statusLabelFontFor(font);
    const CGFloat labelHeight = textFrameHeightForFont(labelFont);
    const CGFloat statusTopMargin = 4.0;
    const CGFloat statusAreaHeight = labelHeight + statusTopMargin;
    label.frame = NSMakeRect(8, HEX_TABLE_HEIGHT - statusTopMargin - labelHeight,
                             tableWidth - 16, labelHeight);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    label.font = labelFont;
    label.textColor = [NSColor secondaryLabelColor];
    label.accessibilityIdentifier = kHexEditorStatusAccessibilityID;
    [rootView addSubview:label];

    NSScrollView *scrollView = [[HexTableScrollView alloc] initWithFrame:NSMakeRect(0, 0, tableWidth, HEX_TABLE_HEIGHT - statusAreaHeight)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSNoBorder;
    // Same windowBackgroundColor as the table so any area the table doesn't
    // cover (under the horizontal scroller, beneath the last row) blends
    // in. Intentionally NOT honouring `g_colorRegularTextBg` here — that
    // would set an opaque table.backgroundColor that NSTableView paints
    // over the current-line / selection highlight rectangles in
    // drawRect:, killing the highlight. Wiring the Regular Text Background
    // well needs a drawBackgroundInClipRect: override so the highlight is
    // composited on top of the canvas bg before row drawing — TODO.
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor windowBackgroundColor];

    NSTableView *table = [[HexTableView alloc] initWithFrame:scrollView.contentView.bounds];
    table.accessibilityIdentifier = kHexEditorTableAccessibilityID;
    table.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    table.usesAlternatingRowBackgroundColors = NO;
    table.gridStyleMask = NSTableViewGridNone;
    table.rowHeight = 18.0;
    table.intercellSpacing = NSMakeSize(0.0, 1.0);
    table.allowsColumnReordering = NO;
    table.allowsColumnResizing = NO;
    table.allowsMultipleSelection = NO;
    table.allowsEmptySelection = YES;
    table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    // Match the surrounding NPP editor pane's background.
    // windowBackgroundColor is dynamic — light gray in light mode, dark
    // gray in dark mode — so the hex view blends with the pane
    // automatically. Honouring g_colorRegularTextBg here would obscure
    // the current-line / selection highlights drawn in drawRect:, see
    // the matching note on the scroll view above.
    table.backgroundColor = [NSColor windowBackgroundColor];
    // Replace the default header view with our column-span-clipped variant
    // so growing the header row under zoom doesn't expose a wide empty fill
    // to the right of the ASCII pane. Frame matches the default's so layout
    // is unchanged.
    if (NSTableHeaderView *defaultHeader = table.headerView) {
        HexTableHeaderView *clippedHeader = [[HexTableHeaderView alloc] initWithFrame:defaultHeader.frame];
        table.headerView = clippedHeader;
    }

    if (!hexTableDataSource) {
        hexTableDataSource = [[HexTableDataSource alloc] init];
    }

    table.dataSource = hexTableDataSource;
    table.delegate = hexTableDataSource;

    addHexCellColumns(table, font);

    applyHexTableLayout(table, label);

    scrollView.documentView = table;
    [rootView addSubview:scrollView];

    // Diagnostic AX surface for tests — see kHexEditorCursorAccessibilityID.
    // 1×1 in the corner so it never affects layout or interactivity.
    HexCursorDiagnosticView *diag = [[HexCursorDiagnosticView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    diag.accessibilityIdentifier = kHexEditorCursorAccessibilityID;
    [rootView addSubview:diag];

    if (statusLabel) {
        *statusLabel = label;
    }

    if (tableView) {
        *tableView = table;
    }

    return rootView;
}

static NSString *makeStatusText()
{
    if (hexBufferEmpty()) {
        return L(@"status.empty");
    }

    // hexBufferLength() and previewTotalLength now both reflect the full
    // Scintilla document length — there's no longer a cap that requires a
    // separate "truncated" status line. The branch is preserved as a single
    // "Showing N bytes." path; the previous truncation banner was retired
    // in Step 2d (page-cached lazy reader removes the need for the cap).
    NSString *baseText = [NSString stringWithFormat:L(@"status.showing"), hexBufferLength()];

    if (hasRectSelection()) {
        // Rectangle status reads e.g. "Rectangle: 4 × 3 (12 bytes)" — the totalBytes
        // value is the unclipped product so the user sees the rectangle's nominal size
        // even when its trailing row runs past EOF.
        NSString *rectText = [NSString stringWithFormat:L(@"status.rectangle"),
            (unsigned long)g_rectSelection.width,
            (unsigned long)g_rectSelection.height,
            (unsigned long)g_rectSelection.totalBytes()];
        return [NSString stringWithFormat:@"%@  %@", baseText, rectText];
    }

    return baseText;
}

static void refreshHexTable(NSTableView *tableView, NSTextField *statusLabel)
{
    NSClipView *clipView = tableView.enclosingScrollView.contentView;
    NSPoint scrollOrigin = clipView.bounds.origin;

    if (statusLabel) {
        statusLabel.stringValue = makeStatusText();
    }

    applyHexTableLayout(tableView, statusLabel);
    [tableView reloadData];
    [clipView scrollToPoint:scrollOrigin];
    [tableView.enclosingScrollView reflectScrolledClipView:clipView];
    restoreHexTableScrollOriginLater(scrollOrigin);
}

static void refreshVisibleHexTables()
{
    refreshHexTable(hexTableView, hexStatusLabel);
}

static void zoomHexFont(NSInteger delta)
{
    const CGFloat oldSize = [hexTableFont() pointSize];
    hexFontZoomDelta += delta;
    const CGFloat newSize = [hexTableFont() pointSize];

    if (newSize == oldSize) {
        return;
    }

    refreshVisibleHexTables();
}

static void resetHexFontZoom()
{
    if (hexFontZoomDelta == 0) {
        return;
    }

    hexFontZoomDelta = 0;
    refreshVisibleHexTables();
}

static void showHexPreview()
{
    previewScintillaHandle = getCurrentScintilla();
    previewBufferId = getCurrentBufferId();
    if (!previewScintillaHandle || previewBufferId == 0) {
        showMessage(L(@"app.titleMac"), L(@"editor.noActiveBuffer"));
        return;
    }

    editorBaseFontSize = readEditorFontSize();
    bindHexBufferToActiveScintilla();
    bookmarkedRows.clear();
    activeByteOffset = 0;
    activeHexNibble = 0;
    activeCursorField = HexCursorField::Hex;
    captureScintillaSelection();

    hexEditorView = currentEditorView();
    hiddenScintillaView = findScintillaView(hexEditorView);
    if (!hexEditorView || !hiddenScintillaView) {
        showMessage(L(@"app.titleMac"), L(@"editor.noActiveView"));
        previewScintillaHandle = 0;
        previewBufferId = 0;
        return;
    }

    if (!hexRootView) {
        hexRootView = createHexTableView(&hexTableView, &hexStatusLabel);
    }

    refreshHexTable(hexTableView, hexStatusLabel);
    hexRootView.frame = NSMakeRect(0, 0, NSWidth(hexEditorView.bounds), NSHeight(hexEditorView.bounds));
    hexRootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [hexRootView removeFromSuperview];
    [hexEditorView addSubview:hexRootView positioned:NSWindowAbove relativeTo:hiddenScintillaView];
    hiddenScintillaView.hidden = YES;
    // Force NSScrollView to retile now that we're in a window. Without this,
    // the column-header bar can end up overlapping the top of the clip view
    // (because tile() ran while the scroll view was still parentless), leaving
    // row 0 partially or fully hidden behind the header. Tiling here positions
    // the header above the clip view and restores the full scrollable range.
    [hexTableView.enclosingScrollView tile];
    // captureScintillaSelection() (above) has already mirrored the host's caret
    // and selection state into activeByteOffset / selectedByteStart-End. Scroll
    // the hex table so that position is visible — landing at the cursor row,
    // which for a real selection is the END of the selection.
    scrollHexTableToActiveOffset();
    [hexTableView.window makeFirstResponder:hexTableView];
    // Remember that the user wants hex view on this buffer so a tab-switch
    // round-trip restores it (instead of relying on the Startup auto-engage
    // heuristic, which only fires for files matching the configured rules).
    recordHexIntent(previewBufferId);
    updateHexMenuCheck(true);
}

static void toggleHexPreview()
{
    if (isHexViewActive() && isPreviewBufferActive()) {
        // User explicitly toggled hex view OFF for this buffer. Drop intent
        // so it stays off across tab switches too. Capture the bufferId
        // before hideHexPreview clears previewBufferId.
        const uintptr_t bufId = previewBufferId;
        hideHexPreview();
        clearHexIntent(bufId);
        return;
    }

    if (isHexViewActive()) {
        hideHexPreview();
    }

    showHexPreview();
}

static void hideHexPreview()
{
    @autoreleasepool {
        if (hiddenScintillaView) {
            hiddenScintillaView.hidden = NO;
        }

        [hexRootView removeFromSuperview];

        if (hiddenScintillaView.window) {
            [hiddenScintillaView.window makeFirstResponder:hiddenScintillaView];
        }

        // Drop the byte-source first so its reference into g_hexReader is
        // released before g_hexReader itself is reset.
        g_hexBuffer.reset();
        g_hexReader.reset();
        bookmarkedRows.clear();
        clearAllByteSelections();
        previewTotalLength = 0;
        previewScintillaHandle = 0;
        previewBufferId = 0;
        hiddenScintillaView = nil;
        hexEditorView = nil;
        updateHexMenuCheck(false);
    }
}

static void showAbout()
{
    NSString *versionLine = [NSString stringWithFormat:L(@"about.version"),
                             [NSString stringWithUTF8String:HEX_PLUGIN_VERSION]];
    NSString *buildLine = [NSString stringWithFormat:L(@"about.build"),
                           [NSString stringWithUTF8String:HEX_PLUGIN_BUILD]];
    NSString *body = [NSString stringWithFormat:@"%@\n\n%@\n%@\n%@\n\n%@",
                      L(@"about.body"),
                      versionLine,
                      buildLine,
                      L(@"about.url"),
                      L(@"about.localeTag")];
    showMessage(L(@"app.titleMac"), body);
}

static void compareHexPreview()
{
    presentHexCompareDialog();
}

static void clearComparePreview()
{
    if (g_compareDiffs.empty()) {
        showMessage(L(@"app.title"), L(@"compare.noActiveResult"));
        return;
    }
    clearHexCompareResult();
}

static void insertColumnsPreview()
{
    if (!isPreviewBufferActive()) {
        showMessage(L(@"app.title"), L(@"insertColumns.openHexFirst"));
        return;
    }
    presentInsertColumnsDialog();
}

static void patternReplacePreview()
{
    presentPatternReplaceDialog();
}

// MARK: - Help popovers

// Round bezel-style "?" button (NSBezelStyleHelpButton) that owns its own NSPopover
// and toggles it on click. Each instance is self-contained — it retains the popover
// (which retains its content controller and view), so callers only need to keep the
// button itself in the view hierarchy.
//
// Dismiss-on-outside-click implementation: NSPopoverBehaviorTransient is supposed
// to auto-dismiss when the user interacts outside the popover, but in practice a
// click on another AppKit control inside the same window often gets consumed by
// that control's tracking loop before the popover sees it. The monitor below
// catches every left-mouse-down at the application level and closes the popover
// whenever the click lands outside the popover's window — except when it hits the
// help button itself (the button's own action handler handles toggle semantics
// without re-entrant close-then-reopen).
@interface HexHelpButton : NSButton <NSPopoverDelegate>
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) id outsideClickMonitor;
- (void)hexShowHelpPopover:(id)sender;
@end

@implementation HexHelpButton

- (void)hexShowHelpPopover:(id)sender
{
    if (self.popover.shown) {
        [self.popover close];
        return;
    }
    self.popover.delegate = self;
    [self.popover showRelativeToRect:self.bounds
                              ofView:self
                       preferredEdge:NSRectEdgeMaxY];
    [self installOutsideClickMonitor];
}

- (void)installOutsideClickMonitor
{
    if (self.outsideClickMonitor != nil) {
        return;
    }
    // This file is MRC (no ARC). __unsafe_unretained gives the block a
    // non-retaining reference to break the retain cycle: button retains the
    // monitor (via the property), the monitor's block would otherwise retain
    // the button. Safe because -dealloc removes the monitor before the button
    // is freed, so the block never fires with a dangling pointer.
    __unsafe_unretained HexHelpButton *unsafeSelf = self;
    self.outsideClickMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                              handler:^NSEvent *(NSEvent *event) {
        if (!unsafeSelf.popover.shown) {
            return event;
        }
        NSWindow *popoverWindow = unsafeSelf.popover.contentViewController.view.window;
        if (event.window == popoverWindow) {
            return event;   // click inside the popover content — leave it
        }
        if (event.window == unsafeSelf.window) {
            // Don't close on a click of the help button itself; the action
            // handler will toggle the popover. Otherwise we'd close-then-reopen.
            const NSPoint locInButton = [unsafeSelf convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(locInButton, unsafeSelf.bounds)) {
                return event;
            }
        }
        [unsafeSelf.popover close];
        return event;   // pass the click through to its target as well
    }];
}

- (void)popoverDidClose:(NSNotification *)notification
{
    if (self.outsideClickMonitor != nil) {
        [NSEvent removeMonitor:self.outsideClickMonitor];
        self.outsideClickMonitor = nil;
    }
}

- (void)dealloc
{
    if (_outsideClickMonitor != nil) {
        [NSEvent removeMonitor:_outsideClickMonitor];
    }
    [super dealloc];
}
@end

// View controller whose loadView produces a soft-padded wrapping label sized to the
// given preferred width. Manual frame layout (no Auto Layout) to match the rest of
// this file, and so the popover knows its exact final size at first show.
@interface HexHelpPopoverController : NSViewController
@property (nonatomic, copy) NSString *helpText;
@property (nonatomic, assign) CGFloat preferredWidth;
@end

@implementation HexHelpPopoverController
- (void)loadView
{
    const CGFloat horizPad = 12.0;
    const CGFloat vertPad = 12.0;
    const CGFloat innerWidth = self.preferredWidth - 2.0 * horizPad;

    NSTextField *label = [NSTextField wrappingLabelWithString:self.helpText ?: @""];
    label.preferredMaxLayoutWidth = innerWidth;
    label.selectable = YES;     // allows VoiceOver / copy of help text
    const NSSize labelSize = label.intrinsicContentSize;
    label.frame = NSMakeRect(horizPad, vertPad, innerWidth, ceil(labelSize.height));

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0,
                                                            self.preferredWidth,
                                                            ceil(labelSize.height) + 2.0 * vertPad)];
    [root addSubview:label];
    self.view = root;
}
@end

// Build a help button that pops `helpText` (already-localized) on click. Caller is
// responsible for placing the returned button (frame is initialised at the AppKit
// standard 22×22; reposition with `button.frame = ...` after creation).
static HexHelpButton *makeHexHelpButton(NSString *helpText, NSString *accessibilityId)
{
    HexHelpButton *button = [[HexHelpButton alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
    button.bezelStyle = NSBezelStyleHelpButton;
    button.title = @"";
    button.bordered = YES;
    if (accessibilityId.length > 0) {
        button.accessibilityIdentifier = accessibilityId;
    }
    // Help button visible label for VoiceOver (the "?" glyph alone reads as
    // unhelpful "help button" without this).
    button.accessibilityLabel = L(@"help.button.axLabel");

    HexHelpPopoverController *controller = [[HexHelpPopoverController alloc] init];
    controller.helpText = helpText;
    controller.preferredWidth = 320.0;

    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = controller;
    popover.behavior = NSPopoverBehaviorTransient;
    popover.animates = YES;
    button.popover = popover;

    button.target = button;
    button.action = @selector(hexShowHelpPopover:);
    return button;
}

// MARK: - Options dialog

// Tags returned by the option-dialog buttons via [NSApp stopModalWithCode:].
// Why an NSWindow (rather than NSAlert): AppKit's NSAlert intercepts events
// through its own modal session, so an inline NSPopover anchored to a help
// button never receives the outside-click signal that would normally dismiss
// it. Building the dialog as a regular NSWindow + [NSApp runModalForWindow:]
// gives popovers the standard event flow they need to behave correctly. It
// also gives us a real window to host an NSTabView when the Options dialog
// grows the four-tab Windows-parity layout (Start Layout / Startup / Colors /
// Font).
// The "OK" button is the commit-and-close action; named "OK" rather than
// "Save" in the UI because this is a hex editor and "Save" would imply saving
// the document. Internal symbols match the user-visible label for clarity.
static const NSInteger kHexOptionsResultOk     = 1;
static const NSInteger kHexOptionsResultReset  = 2;
static const NSInteger kHexOptionsResultCancel = 3;
static const NSInteger kHexOptionsResultApply  = 4;

// Target object that bridges NSButton actions in the modal window to
// [NSApp stopModalWithCode:]. Lives only for the lifetime of presentOptionsDialog.
//
// Also hosts placeholder action selectors for the Start Layout tab's three
// radio groups. AppKit groups radio buttons that share a superview AND an
// action selector, with at most one selected per group; passing target=nil
// action=nil to NSButton.radioButtonWithTitle: silently breaks the
// grouping (radios go additive instead of mutually exclusive). Each
// group's selector is unique so the three groups don't collapse into one.
// The methods themselves are no-ops — we read the radio state in the
// dialog's commit block, not here.
@interface HexOptionsButtonTarget : NSObject
- (void)hexOptionsOk:(id)sender;
- (void)hexOptionsReset:(id)sender;
- (void)hexOptionsCancel:(id)sender;
- (void)hexOptionsApply:(id)sender;
- (void)hexOptionsBitsRadio:(id)sender;
- (void)hexOptionsBaseRadio:(id)sender;
- (void)hexOptionsEndianRadio:(id)sender;
@end

@implementation HexOptionsButtonTarget
- (void)hexOptionsOk:(id)sender     { [NSApp stopModalWithCode:kHexOptionsResultOk];     }
- (void)hexOptionsReset:(id)sender  { [NSApp stopModalWithCode:kHexOptionsResultReset];  }
- (void)hexOptionsCancel:(id)sender { [NSApp stopModalWithCode:kHexOptionsResultCancel]; }
- (void)hexOptionsApply:(id)sender  { [NSApp stopModalWithCode:kHexOptionsResultApply];  }
- (void)hexOptionsBitsRadio:(id)sender   {}
- (void)hexOptionsBaseRadio:(id)sender   {}
- (void)hexOptionsEndianRadio:(id)sender {}
@end

// NSColorWell subclass that exposes its current colour as a stable AX value.
// Default NSColorWell doesn't surface the chosen colour to XCUI — only role
// and identifier — so a UI test can't tell whether Reset actually changed
// the well. We override accessibilityValue to return a lowercase 6-digit
// hex string ("ff0000") taken from the well's sRGB-converted colour. The
// dialog already round-trips wells through sRGB on every assignment (see
// makeWell + applyDefaults / commit) so the conversion here is a no-op
// accessor, not a colour-space change. Used only for the Options dialog's
// nine colour wells; everywhere else NSColorWell is unaffected.
@interface HexAxColorWell : NSColorWell
@end

@implementation HexAxColorWell
- (NSString *)accessibilityValue
{
    NSColor *c = [self.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: self.color;
    if (!c) return @"";
    const int r = (int)round([c redComponent]   * 255.0);
    const int g = (int)round([c greenComponent] * 255.0);
    const int b = (int)round([c blueComponent]  * 255.0);
    return [NSString stringWithFormat:@"%02x%02x%02x", r, g, b];
}
@end

// Build the Startup tab. Two prefs: an extensions list (space-separated)
// and a control-char-density percent threshold. NPPN_BUFFERACTIVATED reads
// these globals and decides whether to auto-open the hex view for the new
// buffer. Mirrors the Windows reference's IDD_OPTION_DLG layout.
//
// applyDefaults / commit blocks: same contract as makeStartLayoutTab.
static NSView *makeStartupTab(NSSize size,
                               void (^*outApplyDefaults)(void),
                               void (^*outCommit)(void))
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];

    const CGFloat innerMargin = 16.0;
    const CGFloat helpButtonSize = 18.0;
    const CGFloat helpButtonGap = 4.0;
    const CGFloat fieldRowHeight = 22.0;
    const CGFloat blockGap = 18.0;
    const CGFloat hintGap = 4.0;

    CGFloat y = size.height - innerMargin;

    // Extensions row -----------------------------------------------------
    // Label "Extensions:" on the left, hint "e.g.: .dat …" on the right of
    // the same line, full-width text field below.
    y -= fieldRowHeight;
    NSTextField *extLabel = [NSTextField labelWithString:L(@"options.startup.extensions.label")];
    [extLabel sizeToFit];
    extLabel.frame = NSMakeRect(innerMargin, y, NSWidth(extLabel.frame), fieldRowHeight);
    [view addSubview:extLabel];

    NSTextField *extHint = [NSTextField labelWithString:L(@"options.startup.extensions.hint")];
    extHint.textColor = [NSColor secondaryLabelColor];
    extHint.alignment = NSTextAlignmentRight;
    [extHint sizeToFit];
    extHint.frame = NSMakeRect(size.width - innerMargin - helpButtonSize - helpButtonGap - NSWidth(extHint.frame),
                                y,
                                NSWidth(extHint.frame), fieldRowHeight);
    [view addSubview:extHint];

    HexHelpButton *extHelp = makeHexHelpButton(L(@"options.startup.extensions.help"),
                                                 @"hex-editor.options.startup.extensions.help");
    extHelp.frame = NSMakeRect(size.width - innerMargin - helpButtonSize,
                                y + (fieldRowHeight - helpButtonSize) / 2.0,
                                helpButtonSize, helpButtonSize);
    [view addSubview:extHelp];

    y -= (hintGap + fieldRowHeight);
    NSTextField *extField = [[NSTextField alloc] initWithFrame:NSMakeRect(innerMargin, y, size.width - 2 * innerMargin, fieldRowHeight)];
    extField.accessibilityIdentifier = @"hex-editor.options.startup.extensions";
    [view addSubview:extField];

    // Percent row --------------------------------------------------------
    y -= (blockGap + fieldRowHeight);
    const CGFloat percentFieldWidth = 60.0;
    const CGFloat percentFieldX = size.width - innerMargin - helpButtonSize - helpButtonGap - percentFieldWidth;
    const CGFloat percentLabelMaxWidth = percentFieldX - innerMargin - 8.0;

    NSTextField *pctLabel = [NSTextField labelWithString:L(@"options.startup.percent.label")];
    pctLabel.frame = NSMakeRect(innerMargin, y, percentLabelMaxWidth, fieldRowHeight);
    [view addSubview:pctLabel];

    NSTextField *pctField = [[NSTextField alloc] initWithFrame:NSMakeRect(percentFieldX, y, percentFieldWidth, fieldRowHeight)];
    pctField.alignment = NSTextAlignmentCenter;
    pctField.accessibilityIdentifier = @"hex-editor.options.startup.percent";
    NSNumberFormatter *pctFormatter = [[NSNumberFormatter alloc] init];
    pctFormatter.numberStyle = NSNumberFormatterNoStyle;
    pctFormatter.allowsFloats = NO;
    pctFormatter.minimum = @0;
    pctFormatter.maximum = @99;
    pctField.formatter = pctFormatter;
    [view addSubview:pctField];

    HexHelpButton *pctHelp = makeHexHelpButton(L(@"options.startup.percent.help"),
                                                 @"hex-editor.options.startup.percent.help");
    pctHelp.frame = NSMakeRect(size.width - innerMargin - helpButtonSize,
                                y + (fieldRowHeight - helpButtonSize) / 2.0,
                                helpButtonSize, helpButtonSize);
    [view addSubview:pctHelp];

    // Initial fill: show the user's currently saved state.
    extField.stringValue = g_autoExtensions ?: @"";
    pctField.stringValue = (g_autoControlPercent > 0)
        ? [NSString stringWithFormat:@"%d", g_autoControlPercent]
        : @"";

    // Reset path: factory defaults (auto-engage off) — not committed until Apply / Ok.
    void (^applyDefaults)(void) = ^{
        extField.stringValue = @"";
        pctField.stringValue = @"";
    };

    void (^commit)(void) = ^{
        NSString *exts = [extField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
        if (![exts isEqualToString:g_autoExtensions ?: @""]) {
            g_autoExtensions = [exts copy];
        }
        const int percent = std::clamp([pctField.stringValue intValue], 0, 99);
        if (percent != g_autoControlPercent) {
            g_autoControlPercent = percent;
        }
        saveHexPrefs();
    };

    if (outApplyDefaults) *outApplyDefaults = [applyDefaults copy];
    if (outCommit) *outCommit = [commit copy];

    return view;
}

// Build the Colors tab. 5×2 grid of NSColorWell controls (Regular Text,
// Selection, Compare, Bookmark, Current Line × Text/Back), with a single
// Help button at the top-right covering the whole tab — there's not enough
// horizontal room to give each row its own help anchor without crowding
// the wells, and the help text would say nearly the same thing for every
// row anyway.
//
// Each well's accessibilityIdentifier is "hex-editor.options.colors.<row>.<col>"
// so UI tests can drive specific cells without depending on tab/row order.
//
// Wells reflect the current g_color* globals on construction. On commit
// we round-trip through colorWellOrNil (returns nil if the well is at its
// "no override" sentinel — see makeColorWell below). Reset clears all
// overrides at once so the hex view falls back to the dynamic defaults.
static NSView *makeColorsTab(NSSize size,
                              void (^*outApplyDefaults)(void),
                              void (^*outCommit)(void))
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];

    const CGFloat innerMargin = 16.0;
    const CGFloat helpButtonSize = 18.0;
    const CGFloat rowHeight = 28.0;
    const CGFloat rowGap = 4.0;
    const CGFloat wellWidth = 60.0;
    const CGFloat wellHeight = 22.0;
    const CGFloat colGap = 12.0;
    const CGFloat headerHeight = 18.0;

    // Right-anchor the two well columns; the row labels stretch from the
    // left margin to the start of the wells.
    const CGFloat backWellX = size.width - innerMargin - helpButtonSize - colGap - wellWidth;
    const CGFloat textWellX = backWellX - colGap - wellWidth;
    const CGFloat labelMaxWidth = textWellX - innerMargin - 8.0;

    // Header row: "Text"  "Back" centered above the two well columns.
    // __block so the addRow helper can advance y down for each row.
    __block CGFloat y = size.height - innerMargin - headerHeight;
    NSTextField *textHeader = [NSTextField labelWithString:L(@"options.colors.header.text")];
    textHeader.alignment = NSTextAlignmentCenter;
    textHeader.textColor = [NSColor secondaryLabelColor];
    textHeader.frame = NSMakeRect(textWellX, y, wellWidth, headerHeight);
    [view addSubview:textHeader];

    NSTextField *backHeader = [NSTextField labelWithString:L(@"options.colors.header.back")];
    backHeader.alignment = NSTextAlignmentCenter;
    backHeader.textColor = [NSColor secondaryLabelColor];
    backHeader.frame = NSMakeRect(backWellX, y, wellWidth, headerHeight);
    [view addSubview:backHeader];

    // Single help button to the right of "Back".
    HexHelpButton *help = makeHexHelpButton(L(@"options.colors.help"),
                                              @"hex-editor.options.colors.help");
    help.frame = NSMakeRect(size.width - innerMargin - helpButtonSize,
                              y + (headerHeight - helpButtonSize) / 2.0,
                              helpButtonSize, helpButtonSize);
    [view addSubview:help];

    y -= 6.0;  // gap between headers and first row

    // Helper to build one well. NSColorWell stores the current colour
    // verbatim — including its colour space — and the system colour panel
    // restricts its picker to whatever space the well is currently in. If
    // we feed the well a grayscale colour like [NSColor labelColor]
    // (which resolves to black in light mode in a Gray colour space), the
    // panel opens locked to "shades of black". Convert to sRGB before
    // assignment so the user always gets the full RGB picker.
    NSColorWell *(^makeWell)(NSString *, NSColor *, CGFloat, CGFloat) =
    ^NSColorWell *(NSString *axId, NSColor *initial, CGFloat wx, CGFloat wy) {
        NSColorWell *well = [[HexAxColorWell alloc] initWithFrame:NSMakeRect(wx, wy, wellWidth, wellHeight)];
        well.accessibilityIdentifier = axId;
        if (initial) {
            NSColor *rgb = [initial colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            well.color = rgb ?: initial;
        }
        [view addSubview:well];
        return well;
    };

    NSColorWell *(^addRow)(NSString *, NSString *, BOOL, NSColor *, NSColor *,
                            NSColorWell *__strong *,
                            NSColorWell *__strong *) =
    ^NSColorWell *(NSString *labelKey, NSString *axBase, BOOL hasFg,
                    NSColor *fgColor, NSColor *bgColor,
                    NSColorWell *__strong *outFg, NSColorWell *__strong *outBg) {
        y -= (rowHeight + rowGap);
        NSTextField *rowLabel = [NSTextField labelWithString:L(labelKey)];
        rowLabel.alignment = NSTextAlignmentRight;
        rowLabel.frame = NSMakeRect(innerMargin, y + (rowHeight - rowLabel.intrinsicContentSize.height) / 2.0,
                                     labelMaxWidth, rowLabel.intrinsicContentSize.height);
        [view addSubview:rowLabel];

        const CGFloat wy = y + (rowHeight - wellHeight) / 2.0;
        if (hasFg) {
            NSColorWell *fg = makeWell([NSString stringWithFormat:@"hex-editor.options.colors.%@.fg", axBase],
                                         fgColor, textWellX, wy);
            if (outFg) *outFg = fg;
        }
        NSColorWell *bg = makeWell([NSString stringWithFormat:@"hex-editor.options.colors.%@.bg", axBase],
                                     bgColor, backWellX, wy);
        if (outBg) *outBg = bg;
        return bg;
    };

    NSColorWell *regFg = nil, *regBg = nil;
    NSColorWell *selFg = nil, *selBg = nil;
    NSColorWell *cmpFg = nil, *cmpBg = nil;
    NSColorWell *bmkFg = nil, *bmkBg = nil;
    NSColorWell *curBg = nil;

    // Initial fill comes straight from the resolve helpers — they already
    // pick the current mode's override (or factory fallback if none) so we
    // don't need to repeat the branch here.
    addRow(@"options.colors.row.regularText", @"regularText", YES,
            hexRegularTextColor(),
            hexRegularTextBackgroundColor(),
            &regFg, &regBg);
    addRow(@"options.colors.row.selection", @"selection", YES,
            hexSelectionTextColor(),
            hexSelectionColor(),
            &selFg, &selBg);
    addRow(@"options.colors.row.compare", @"compare", YES,
            hexCompareDiffTextColor(),
            hexCompareDiffColor(),
            &cmpFg, &cmpBg);
    addRow(@"options.colors.row.bookmark", @"bookmark", YES,
            hexBookmarkTextColor(),
            hexBookmarkBackgroundColor(),
            &bmkFg, &bmkBg);
    addRow(@"options.colors.row.currentLine", @"currentLine", NO,
            nil, hexCurrentLineColor(),
            nil, &curBg);

    // Round-trip every well's colour through sRGB so the system colour
    // panel always opens in full RGB mode. See makeWell above for why.
    NSColor *(^toRGB)(NSColor *) = ^NSColor *(NSColor *c) {
        if (!c) return nil;
        NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        return rgb ?: c;
    };
    // Reset path: show the factory-default colours (Windows-equivalent
    // hard-coded values, matching what the hex…Color() resolve helpers fall
    // back to when no override is set). We don't touch the g_colorXxx
    // globals here — Reset only updates the dialog UI. Apply / Ok commits
    // whatever's in the wells; Cancel discards the reset.
    void (^applyDefaults)(void) = ^{
        regFg.color = toRGB(hexFactoryRegularTextFg());
        regBg.color = toRGB(hexFactoryRegularTextBg());
        selFg.color = toRGB(hexFactorySelectionFg());
        selBg.color = toRGB(hexFactorySelectionBg());
        cmpFg.color = toRGB(hexFactoryCompareFg());
        cmpBg.color = toRGB(hexFactoryCompareBg());
        bmkFg.color = toRGB(hexFactoryBookmarkFg());
        bmkBg.color = toRGB(hexFactoryBookmarkBg());
        curBg.color = toRGB(hexFactoryCurrentLineBg());
    };

    void (^commit)(void) = ^{
        // For each well: if its colour matches the current-mode factory,
        // CLEAR the override (g_color = nil) instead of saving the static
        // factory hex. This is what makes Reset → Apply mode-adaptive: a
        // cleared override falls back to hexFactory*() at render time,
        // which re-evaluates on every paint and switches between Light /
        // Dark factories as NSApp.appearance changes. If we instead saved
        // the factory snapshot as an override, switching modes would show
        // the wrong mode's hexes (the user reported this on 2026-05-03:
        // Reset+Apply in Light, then switch to Dark, still saw Light hexes).
        //
        // A user who picks a custom colour that happens to exactly match
        // the factory will silently get a cleared override instead of a
        // pinned override — acceptable edge case, the rendered result is
        // identical for the current mode and gains mode-adaptive behaviour.
        NSColor *(^toRGB)(NSColor *) = ^NSColor *(NSColor *c) {
            if (!c) return nil;
            NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            return rgb ?: c;
        };
        BOOL (^matches)(NSColorWell *, NSColor *) = ^BOOL(NSColorWell *well, NSColor *factory) {
            return [well.color isEqual:toRGB(factory)];
        };
        // Commit to the CURRENT mode's slot only — leaves the other mode's
        // override untouched, so customising Selection bg in Light doesn't
        // disturb whatever the user picked (or didn't pick) in Dark.
        const BOOL isDark = hexEffectiveAppearanceIsDark();
        NSColor **slotRegFg = isDark ? &g_colorRegularTextFgDark : &g_colorRegularTextFgLight;
        NSColor **slotRegBg = isDark ? &g_colorRegularTextBgDark : &g_colorRegularTextBgLight;
        NSColor **slotSelFg = isDark ? &g_colorSelectionFgDark   : &g_colorSelectionFgLight;
        NSColor **slotSelBg = isDark ? &g_colorSelectionBgDark   : &g_colorSelectionBgLight;
        NSColor **slotCmpFg = isDark ? &g_colorCompareFgDark     : &g_colorCompareFgLight;
        NSColor **slotCmpBg = isDark ? &g_colorCompareBgDark     : &g_colorCompareBgLight;
        NSColor **slotBmkFg = isDark ? &g_colorBookmarkFgDark    : &g_colorBookmarkFgLight;
        NSColor **slotBmkBg = isDark ? &g_colorBookmarkBgDark    : &g_colorBookmarkBgLight;
        NSColor **slotCurBg = isDark ? &g_colorCurrentLineBgDark : &g_colorCurrentLineBgLight;
        setHexColor(slotRegFg, matches(regFg, hexFactoryRegularTextFg()) ? nil : regFg.color);
        setHexColor(slotRegBg, matches(regBg, hexFactoryRegularTextBg()) ? nil : regBg.color);
        setHexColor(slotSelFg, matches(selFg, hexFactorySelectionFg())   ? nil : selFg.color);
        setHexColor(slotSelBg, matches(selBg, hexFactorySelectionBg())   ? nil : selBg.color);
        setHexColor(slotCmpFg, matches(cmpFg, hexFactoryCompareFg())     ? nil : cmpFg.color);
        setHexColor(slotCmpBg, matches(cmpBg, hexFactoryCompareBg())     ? nil : cmpBg.color);
        setHexColor(slotBmkFg, matches(bmkFg, hexFactoryBookmarkFg())    ? nil : bmkFg.color);
        setHexColor(slotBmkBg, matches(bmkBg, hexFactoryBookmarkBg())    ? nil : bmkBg.color);
        setHexColor(slotCurBg, matches(curBg, hexFactoryCurrentLineBg()) ? nil : curBg.color);
        saveHexPrefs();
        // Repaint the live table so per-cell colour changes (selection,
        // compare, bookmark) are visible immediately.
        if (hexTableView != nil) {
            [hexTableView reloadData];
            [hexTableView setNeedsDisplay:YES];
            [hexTableView.headerView setNeedsDisplay:YES];
        }
    };

    if (outApplyDefaults) *outApplyDefaults = [applyDefaults copy];
    if (outCommit) *outCommit = [commit copy];

    return view;
}

// Build the Font tab. Layout (top → bottom):
//
//   [Font Name:]  [popup of monospaced fonts ........................ ]  [?]
//   [Font Size:]  [popup of point sizes]              [Bold]
//                                                     [Italic]
//                 [Capital letters mode]
//                 [Mirror Cursor as Rect]             [Underline]
//
// applyDefaults / commit blocks: same contract as makeStartLayoutTab — Reset
// rewrites the in-dialog state to the factory defaults (Menlo / 12pt /
// nothing on / mirror cursor on); commit reads the in-dialog state and
// writes through to globals + NSUserDefaults. The font popup is filtered to
// fixed-pitch families via NSFontManager.availableFontNamesWithTraits:
// (NSFixedPitchFontMask) so the user picks from typefaces that actually
// align in the byte grid.
static NSView *makeFontTab(NSSize size,
                            void (^*outApplyDefaults)(void),
                            void (^*outCommit)(void))
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];

    const CGFloat innerMargin = 16.0;
    const CGFloat rowHeight = 26.0;
    const CGFloat rowGap = 6.0;
    const CGFloat labelMaxWidth = 110.0;
    const CGFloat helpButtonSize = 18.0;
    const CGFloat helpButtonGap = 4.0;
    // Gap between the left-column checkboxes (Capital letters mode, Mirror
    // Cursor as Rect — long localised labels) and the right-column trait
    // toggles (Bold, Italic, Underline). The right column's X is computed
    // below from the *measured* intrinsic widths of the left-column labels
    // so localisations that grow the labels don't collide with the right
    // column. 24pt is the gap, measured visually in the same way other
    // tabs space their controls.
    const CGFloat columnGap = 24.0;

    // Right-anchored help button column lives where the Colors tab's well
    // column does — keeps the dialog's right gutter visually consistent.
    const CGFloat rightEdge = size.width - innerMargin;
    const CGFloat helpX = rightEdge - helpButtonSize;
    const CGFloat fieldRightEdge = helpX - helpButtonGap;

    // Top-down y cursor.
    __block CGFloat y = size.height - innerMargin - rowHeight;

    NSPopUpButton *fontNamePopup = nil;
    NSPopUpButton *fontSizePopup = nil;

    // Build the five checkboxes up front and call sizeToFit so we can
    // measure their localised widths and pick a column-2 X that doesn't
    // collide with the longest left-column label in the active locale.
    NSButton *boldCheckbox      = [NSButton checkboxWithTitle:L(@"options.font.bold")              target:nil action:NULL];
    NSButton *italicCheckbox    = [NSButton checkboxWithTitle:L(@"options.font.italic")            target:nil action:NULL];
    NSButton *underlineCheckbox = [NSButton checkboxWithTitle:L(@"options.font.underline")         target:nil action:NULL];
    NSButton *uppercaseCheckbox = [NSButton checkboxWithTitle:L(@"options.font.uppercaseHex")      target:nil action:NULL];
    NSButton *mirrorCursorCheckbox = [NSButton checkboxWithTitle:L(@"options.font.mirrorAsciiCursor") target:nil action:NULL];
    boldCheckbox.accessibilityIdentifier         = @"hex-editor.options.font.bold";
    italicCheckbox.accessibilityIdentifier       = @"hex-editor.options.font.italic";
    underlineCheckbox.accessibilityIdentifier    = @"hex-editor.options.font.underline";
    uppercaseCheckbox.accessibilityIdentifier    = @"hex-editor.options.font.uppercaseHex";
    mirrorCursorCheckbox.accessibilityIdentifier = @"hex-editor.options.font.mirrorAsciiCursor";
    [boldCheckbox sizeToFit];
    [italicCheckbox sizeToFit];
    [underlineCheckbox sizeToFit];
    [uppercaseCheckbox sizeToFit];
    [mirrorCursorCheckbox sizeToFit];

    // Row 1: Font Name label + popup + help button.
    NSTextField *fontNameLabel = [NSTextField labelWithString:L(@"options.font.name")];
    fontNameLabel.alignment = NSTextAlignmentRight;
    fontNameLabel.frame = NSMakeRect(innerMargin,
                                       y + (rowHeight - fontNameLabel.intrinsicContentSize.height) / 2.0,
                                       labelMaxWidth,
                                       fontNameLabel.intrinsicContentSize.height);
    [view addSubview:fontNameLabel];

    const CGFloat popupX = innerMargin + labelMaxWidth + 8.0;
    fontNamePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(popupX, y, fieldRightEdge - popupX, rowHeight) pullsDown:NO];
    fontNamePopup.accessibilityIdentifier = @"hex-editor.options.font.name";
    // Filter to fixed-pitch families. NSFontManager doesn't fold mismatched
    // synonyms (e.g. "Courier" vs "Courier New"), so de-dupe via NSSet.
    NSArray<NSString *> *monospacedFamilies = [[NSFontManager sharedFontManager]
        availableFontNamesWithTraits:NSFixedPitchFontMask] ?: @[];
    NSMutableArray<NSString *> *families = [NSMutableArray arrayWithCapacity:monospacedFamilies.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:monospacedFamilies.count];
    for (NSString *fontName in monospacedFamilies) {
        // availableFontNamesWithTraits: returns PostScript names (e.g.
        // "Menlo-Regular", "Menlo-Bold"). Convert to the family name so the
        // popup shows one row per typeface, not one per weight/style.
        NSFont *probe = [NSFont fontWithName:fontName size:12.0];
        NSString *family = probe.familyName ?: fontName;
        if (![seen containsObject:family]) {
            [seen addObject:family];
            [families addObject:family];
        }
    }
    [families sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [fontNamePopup addItemsWithTitles:families];
    [view addSubview:fontNamePopup];

    HexHelpButton *fontHelp = makeHexHelpButton(L(@"options.font.help"),
                                                  @"hex-editor.options.font.help");
    fontHelp.frame = NSMakeRect(helpX,
                                 y + (rowHeight - helpButtonSize) / 2.0,
                                 helpButtonSize, helpButtonSize);
    [view addSubview:fontHelp];

    y -= (rowHeight + rowGap);

    // Row 2: Font Size label + popup + Bold checkbox.
    NSTextField *fontSizeLabel = [NSTextField labelWithString:L(@"options.font.size")];
    fontSizeLabel.alignment = NSTextAlignmentRight;
    fontSizeLabel.frame = NSMakeRect(innerMargin,
                                       y + (rowHeight - fontSizeLabel.intrinsicContentSize.height) / 2.0,
                                       labelMaxWidth,
                                       fontSizeLabel.intrinsicContentSize.height);
    [view addSubview:fontSizeLabel];

    const CGFloat sizePopupWidth = 70.0;
    fontSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(popupX, y, sizePopupWidth, rowHeight) pullsDown:NO];
    fontSizePopup.accessibilityIdentifier = @"hex-editor.options.font.size";
    NSArray<NSNumber *> *sizes = @[@10, @11, @12, @13, @14, @16, @18, @20, @24, @28, @32];
    for (NSNumber *sz in sizes) {
        [fontSizePopup addItemWithTitle:[sz stringValue]];
    }
    [view addSubview:fontSizePopup];

    // Right-column X. The right column hosts the short trait toggles
    // (Bold / Italic / Underline) on rows 2-4 and must clear:
    //   - the size popup on row 2 (so Bold doesn't overlap it),
    //   - the longest left-column checkbox on rows 3-4 (Capital letters
    //     mode and Mirror Cursor as Rect, both ~150-170pt at en, but
    //     longer in other locales — measured here, not assumed).
    const CGFloat leftMax = MAX(NSWidth(uppercaseCheckbox.frame),
                                 NSWidth(mirrorCursorCheckbox.frame));
    const CGFloat rightColumnX = MAX(popupX + sizePopupWidth, popupX + leftMax) + columnGap;

    auto placeCheckbox = ^(NSButton *cb, CGFloat cx, CGFloat cy) {
        cb.frame = NSMakeRect(cx,
                               cy + (rowHeight - NSHeight(cb.frame)) / 2.0,
                               NSWidth(cb.frame),
                               NSHeight(cb.frame));
        [view addSubview:cb];
    };

    // Row 2 right: Bold.
    placeCheckbox(boldCheckbox, rightColumnX, y);

    y -= (rowHeight + rowGap);

    // Row 3: Capital letters (left) + Italic (right).
    placeCheckbox(uppercaseCheckbox, popupX, y);
    placeCheckbox(italicCheckbox, rightColumnX, y);

    y -= (rowHeight + rowGap);

    // Row 4: Mirror Cursor (left) + Underline (right).
    placeCheckbox(mirrorCursorCheckbox, popupX, y);
    placeCheckbox(underlineCheckbox, rightColumnX, y);

    // Helpers used by both the initial fill and applyDefaults / commit.
    void (^selectFontNameInPopup)(NSString *) = ^(NSString *family) {
        // If the requested family isn't in our filtered list (renamed,
        // uninstalled, or not strictly fixed-pitch on this system), just
        // keep the popup's first item — the commit block normalises the
        // selection back into the prefs.
        NSInteger idx = [fontNamePopup indexOfItemWithTitle:family];
        if (idx >= 0) [fontNamePopup selectItemAtIndex:idx];
    };
    void (^selectFontSizeInPopup)(int) = ^(int sz) {
        NSString *title = [NSString stringWithFormat:@"%d", sz];
        NSInteger idx = [fontSizePopup indexOfItemWithTitle:title];
        if (idx < 0) idx = [fontSizePopup indexOfItemWithTitle:[NSString stringWithFormat:@"%d", HEX_DEFAULT_FONT_SIZE_PT]];
        if (idx >= 0) [fontSizePopup selectItemAtIndex:idx];
    };

    // Initial fill: show the user's currently saved state.
    selectFontNameInPopup(g_fontName ?: HEX_DEFAULT_FONT_NAME);
    selectFontSizeInPopup(g_fontSize);
    boldCheckbox.state         = g_fontBold          ? NSControlStateValueOn : NSControlStateValueOff;
    italicCheckbox.state       = g_fontItalic        ? NSControlStateValueOn : NSControlStateValueOff;
    underlineCheckbox.state    = g_fontUnderline     ? NSControlStateValueOn : NSControlStateValueOff;
    uppercaseCheckbox.state    = g_uppercaseHex      ? NSControlStateValueOn : NSControlStateValueOff;
    mirrorCursorCheckbox.state = g_mirrorAsciiCursor ? NSControlStateValueOn : NSControlStateValueOff;

    // Reset path: factory defaults (no commit until Apply / Ok).
    void (^applyDefaults)(void) = ^{
        selectFontNameInPopup(HEX_DEFAULT_FONT_NAME);
        selectFontSizeInPopup(HEX_DEFAULT_FONT_SIZE_PT);
        boldCheckbox.state         = NSControlStateValueOff;
        italicCheckbox.state       = NSControlStateValueOff;
        underlineCheckbox.state    = NSControlStateValueOff;
        uppercaseCheckbox.state    = NSControlStateValueOff;
        mirrorCursorCheckbox.state = NSControlStateValueOff;
    };

    void (^commit)(void) = ^{
        NSString *picked = fontNamePopup.titleOfSelectedItem ?: HEX_DEFAULT_FONT_NAME;
        if (![picked isEqualToString:g_fontName ?: @""]) {
            [g_fontName release];
            g_fontName = [picked copy];
        }
        const int picSize = std::clamp([fontSizePopup.titleOfSelectedItem intValue],
                                          HEX_FONT_SIZE_MIN_PT, HEX_FONT_SIZE_MAX_PT);
        g_fontSize          = (picSize > 0) ? picSize : HEX_DEFAULT_FONT_SIZE_PT;
        g_fontBold          = boldCheckbox.state         == NSControlStateValueOn;
        g_fontItalic        = italicCheckbox.state       == NSControlStateValueOn;
        g_fontUnderline     = underlineCheckbox.state    == NSControlStateValueOn;
        g_uppercaseHex      = uppercaseCheckbox.state    == NSControlStateValueOn;
        g_mirrorAsciiCursor = mirrorCursorCheckbox.state == NSControlStateValueOn;
        saveHexPrefs();
        // No live-render hookup yet — Phase 1 (this commit) only persists
        // the choices. Phase 2/3/4 wire each setting to the actual rendering
        // path (font, traits, casing, mirror cursor); commit will start
        // calling reload after those land.
    };

    if (outApplyDefaults) *outApplyDefaults = [applyDefaults copy];
    if (outCommit) *outCommit = [commit copy];

    return view;
}

// Build a placeholder NSView for tabs we haven't implemented yet. Centered
// label "This tab will be populated in a future update."
static NSView *makeOptionsPlaceholderTab(NSSize size)
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    NSTextField *label = [NSTextField labelWithString:L(@"options.tab.placeholder")];
    label.textColor = [NSColor secondaryLabelColor];
    [label sizeToFit];
    label.frame = NSMakeRect((size.width - NSWidth(label.frame)) / 2.0,
                              (size.height - NSHeight(label.frame)) / 2.0,
                              NSWidth(label.frame), NSHeight(label.frame));
    [view addSubview:label];
    return view;
}

// Build the Start Layout tab. Three radio-button groups in a horizontal row
// (bits/cell, base, endianness), then two number fields below (column count,
// address width). Mirrors the Windows IDD_OPTION_DLG layout. Mutates the
// passed-by-reference popup pointers so the caller can read selections back.
//
// applyDefaults / commit blocks: caller invokes applyDefaults on Reset to
// rewrite the in-dialog state to factory defaults (NOT the saved globals —
// Reset is non-destructive until the user clicks Apply / Ok). commit reads
// the in-dialog state and writes through to globals + NSUserDefaults.
// Keeps the tab self-contained.
static NSView *makeStartLayoutTab(NSSize size,
                                   void (^*outApplyDefaults)(void),
                                   void (^*outCommit)(void))
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];

    const CGFloat innerMargin = 16.0;
    const CGFloat columnGap = 16.0;
    const CGFloat groupColumnWidth = (size.width - 2 * innerMargin - 2 * columnGap) / 3.0;
    const CGFloat radioRowHeight = 18.0;
    const CGFloat radioGap = 2.0;
    const CGFloat fieldRowHeight = 22.0;
    const CGFloat fieldRowGap = 6.0;
    const CGFloat labelToFieldGap = 8.0;
    const CGFloat numericFieldWidth = 60.0;
    const CGFloat helpButtonSize = 18.0;
    const CGFloat helpButtonGap = 4.0;

    // Layout from top down: 4 radio rows (bits column has 4 entries; the
    // others have 2, so the bits column dictates the radio block height).
    const CGFloat radioBlockHeight = 4 * radioRowHeight + 3 * radioGap;
    const CGFloat fieldBlockHeight = 2 * fieldRowHeight + fieldRowGap;
    const CGFloat blockGap = 16.0;
    const CGFloat totalContentHeight = radioBlockHeight + blockGap + fieldBlockHeight;
    CGFloat y = (size.height - totalContentHeight) / 2.0 + radioBlockHeight + blockGap + fieldBlockHeight;

    // Helper to lay out a vertical column of radio buttons with optional
    // help button to the right of the column header. Returns the row of
    // radio button objects in the order requested.
    //
    // Each group needs a unique target+action pair so AppKit's radio-button
    // grouping kicks in (same superview + same action selector → mutually
    // exclusive selection within that group). Passing nil/nil leaves them
    // additive — multiple buttons in the group can be on at once.
    HexOptionsButtonTarget *radioTarget = [[HexOptionsButtonTarget alloc] init];
    NSMutableArray<NSButton *> *(^makeRadioGroup)(NSArray<NSString *> *, CGFloat, CGFloat, NSString *, NSString *, NSString *, SEL) =
    ^NSMutableArray<NSButton *> *(NSArray<NSString *> *titles, CGFloat startX, CGFloat startY, NSString *axIdPrefix, NSString *helpAxId, NSString *helpText, SEL groupAction) {
        NSMutableArray<NSButton *> *group = [NSMutableArray arrayWithCapacity:titles.count];
        CGFloat ry = startY - radioRowHeight;
        for (NSUInteger i = 0; i < titles.count; ++i) {
            NSButton *radio = [NSButton radioButtonWithTitle:titles[i] target:radioTarget action:groupAction];
            radio.frame = NSMakeRect(startX, ry, groupColumnWidth - helpButtonSize - helpButtonGap, radioRowHeight);
            radio.accessibilityIdentifier = [NSString stringWithFormat:@"%@.%@",
                axIdPrefix, [titles[i] stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
            [view addSubview:radio];
            [group addObject:radio];
            ry -= (radioRowHeight + radioGap);
        }
        // Help button next to the first radio in the group.
        HexHelpButton *help = makeHexHelpButton(helpText, helpAxId);
        help.frame = NSMakeRect(startX + groupColumnWidth - helpButtonSize,
                                 startY - radioRowHeight + (radioRowHeight - helpButtonSize) / 2.0,
                                 helpButtonSize, helpButtonSize);
        [view addSubview:help];
        return group;
    };

    // Bits per cell column: 8/16/32/64
    NSMutableArray<NSButton *> *bitsRadios = makeRadioGroup(
        @[L(@"options.startLayout.bits.8"),
          L(@"options.startLayout.bits.16"),
          L(@"options.startLayout.bits.32"),
          L(@"options.startLayout.bits.64")],
        innerMargin, y,
        @"hex-editor.options.startLayout.bits",
        @"hex-editor.options.startLayout.bits.help",
        L(@"options.startLayout.bits.help"),
        @selector(hexOptionsBitsRadio:));

    // Base column: Hexadecimal / Binary
    NSMutableArray<NSButton *> *baseRadios = makeRadioGroup(
        @[L(@"options.startLayout.base.hex"),
          L(@"options.startLayout.base.binary")],
        innerMargin + groupColumnWidth + columnGap, y,
        @"hex-editor.options.startLayout.base",
        @"hex-editor.options.startLayout.base.help",
        L(@"options.startLayout.base.help"),
        @selector(hexOptionsBaseRadio:));

    // Endianness column: Little / Big. Little-Endian is listed first
    // because it's the default and matches every system the user is
    // likely to be inspecting bytes from (Apple Silicon, Intel, ARM,
    // Windows). Big-Endian is the niche entry for network packet dumps.
    // Index 0 = Little, Index 1 = Big — keep this consistent with the
    // initial-fill / commit / Reset logic below (all keyed on index).
    NSMutableArray<NSButton *> *endianRadios = makeRadioGroup(
        @[L(@"options.startLayout.endian.little"),
          L(@"options.startLayout.endian.big")],
        innerMargin + 2 * (groupColumnWidth + columnGap), y,
        @"hex-editor.options.startLayout.endian",
        @"hex-editor.options.startLayout.endian.help",
        L(@"options.startLayout.endian.help"),
        @selector(hexOptionsEndianRadio:));

    // Drop down to the field block.
    y -= radioBlockHeight + blockGap;

    // Column Count + Address Width fields stack vertically. Label on the
    // left, numeric text field on the right, help button beyond that.
    const CGFloat fieldX = size.width - innerMargin - helpButtonSize - helpButtonGap - numericFieldWidth;
    const CGFloat labelMaxWidth = fieldX - innerMargin - labelToFieldGap;

    NSTextField *colLabel = [NSTextField labelWithString:L(@"options.startLayout.columnCount")];
    colLabel.alignment = NSTextAlignmentRight;
    colLabel.frame = NSMakeRect(innerMargin, y - fieldRowHeight, labelMaxWidth, fieldRowHeight);
    [view addSubview:colLabel];

    NSTextField *colField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y - fieldRowHeight, numericFieldWidth, fieldRowHeight)];
    colField.alignment = NSTextAlignmentCenter;
    colField.accessibilityIdentifier = @"hex-editor.options.startLayout.columnCount";
    NSNumberFormatter *colFormatter = [[NSNumberFormatter alloc] init];
    colFormatter.numberStyle = NSNumberFormatterNoStyle;
    colFormatter.allowsFloats = NO;
    colFormatter.minimum = @1;
    colField.formatter = colFormatter;
    [view addSubview:colField];

    HexHelpButton *colHelp = makeHexHelpButton(L(@"options.startLayout.columnCount.help"),
                                                @"hex-editor.options.startLayout.columnCount.help");
    colHelp.frame = NSMakeRect(fieldX + numericFieldWidth + helpButtonGap,
                                y - fieldRowHeight + (fieldRowHeight - helpButtonSize) / 2.0,
                                helpButtonSize, helpButtonSize);
    [view addSubview:colHelp];

    y -= (fieldRowHeight + fieldRowGap);

    NSTextField *addrLabel = [NSTextField labelWithString:L(@"options.startLayout.addressWidth")];
    addrLabel.alignment = NSTextAlignmentRight;
    addrLabel.frame = NSMakeRect(innerMargin, y - fieldRowHeight, labelMaxWidth, fieldRowHeight);
    [view addSubview:addrLabel];

    NSTextField *addrField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y - fieldRowHeight, numericFieldWidth, fieldRowHeight)];
    addrField.alignment = NSTextAlignmentCenter;
    addrField.accessibilityIdentifier = @"hex-editor.options.startLayout.addressWidth";
    NSNumberFormatter *addrFormatter = [[NSNumberFormatter alloc] init];
    addrFormatter.numberStyle = NSNumberFormatterNoStyle;
    addrFormatter.allowsFloats = NO;
    addrFormatter.minimum = @(HEX_MIN_ADDRESS_WIDTH);
    addrFormatter.maximum = @(HEX_MAX_ADDRESS_WIDTH);
    addrField.formatter = addrFormatter;
    [view addSubview:addrField];

    HexHelpButton *addrHelp = makeHexHelpButton(L(@"options.startLayout.addressWidth.help"),
                                                 @"hex-editor.options.startLayout.addressWidth.help");
    addrHelp.frame = NSMakeRect(fieldX + numericFieldWidth + helpButtonGap,
                                 y - fieldRowHeight + (fieldRowHeight - helpButtonSize) / 2.0,
                                 helpButtonSize, helpButtonSize);
    [view addSubview:addrHelp];

    // Apply defaults / commit hooks ---------------------------------------

    int (^bitsToIndex)(int) = ^int(int bytes) {
        switch (bytes) {
            case 1: return 0;
            case 2: return 1;
            case 4: return 2;
            case 8: return 3;
        }
        return 0;
    };
    int (^indexToBits)(NSInteger) = ^int(NSInteger idx) {
        switch (idx) {
            case 0: return 1;
            case 1: return 2;
            case 2: return 4;
            case 3: return 8;
        }
        return 1;
    };
    NSButton *(^selectedRadio)(NSArray<NSButton *> *) = ^NSButton *(NSArray<NSButton *> *group) {
        for (NSButton *r in group) {
            if (r.state == NSControlStateValueOn) return r;
        }
        return nil;
    };
    void (^selectRadioAtIndex)(NSArray<NSButton *> *, NSUInteger) = ^(NSArray<NSButton *> *group, NSUInteger idx) {
        for (NSUInteger i = 0; i < group.count; ++i) {
            group[i].state = (i == idx) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    };
    // Endianness radios stay enabled regardless of bits-per-column. The
    // setting is meaningless when 8-Bit is selected (single bytes are
    // always shown in address-ascending order) but the help popover
    // explains that, and keeping the radios live is consistent with the
    // Windows reference dialog.

    // Initial fill: show the user's currently saved state.
    selectRadioAtIndex(bitsRadios, bitsToIndex(g_bytesPerCell));
    {
        const hexedit::ViewMode m = currentViewMode();
        selectRadioAtIndex(baseRadios, m.notation == hexedit::CellNotation::Binary ? 1 : 0);
    }
    selectRadioAtIndex(endianRadios, g_littleEndian ? 0 : 1);  // 0 = Little (default), 1 = Big
    colField.stringValue = [NSString stringWithFormat:@"%d", g_columns];
    addrField.stringValue = [NSString stringWithFormat:@"%d", g_addressWidth];

    // Reset path: show factory defaults in the dialog without committing.
    // The user must click Apply / Ok afterwards to persist them; Cancel
    // discards the reset and the saved state remains untouched.
    void (^applyDefaults)(void) = ^{
        selectRadioAtIndex(bitsRadios, bitsToIndex(1));
        selectRadioAtIndex(baseRadios, 0);
        selectRadioAtIndex(endianRadios, 0);
        colField.stringValue = [NSString stringWithFormat:@"%d", HEX_DEFAULT_COLUMNS];
        addrField.stringValue = [NSString stringWithFormat:@"%d", HEX_DEFAULT_ADDRESS_WIDTH];
    };

    void (^commit)(void) = ^{
        NSButton *bitsSel = selectedRadio(bitsRadios);
        const int bits = indexToBits(bitsSel ? [bitsRadios indexOfObject:bitsSel] : 0);
        NSButton *baseSel = selectedRadio(baseRadios);
        const BOOL binary = baseSel && [baseRadios indexOfObject:baseSel] == 1;
        NSButton *endianSel = selectedRadio(endianRadios);
        const BOOL little = endianSel && [endianRadios indexOfObject:endianSel] == 0;  // 0 = Little, 1 = Big

        if (bits != g_bytesPerCell) {
            setHexViewBytesPerCell(bits);
        }
        // Number base + endianness via toggle helpers (idempotent if no change).
        const hexedit::ViewMode currentMode = currentViewMode();
        if ((currentMode.notation == hexedit::CellNotation::Binary) != (binary != NO)) {
            toggleHexViewBinary();
        }
        // Endian commits regardless of bits-per-cell so the preference
        // persists through a temporary 8-bit selection. formatCell
        // ignores the flag at bpc=1 anyway, so storing it is benign;
        // re-render only when bpc > 1 (where the flag has visible effect).
        // Bypassing toggleHexViewEndian()'s bpc-1 early-return: that
        // helper exists for the menu toggle which is only enabled at
        // bpc > 1; the Options dialog should set the slot regardless.
        if (g_littleEndian != (little != NO)) {
            g_littleEndian = (little != NO);
            saveHexPrefs();
            if (g_bytesPerCell > 1) {
                applyHexViewMode();
            }
        }

        const int colVal = std::clamp([colField.stringValue intValue], 1,
                                       columnsLimitForBytesPerCell(g_bytesPerCell));
        if (colVal != g_columns) {
            setHexColumns(colVal);
        }
        const int addrVal = std::clamp([addrField.stringValue intValue],
                                        HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
        if (addrVal != g_addressWidth) {
            setHexAddressWidth(addrVal);
        }
    };

    if (outApplyDefaults) *outApplyDefaults = [applyDefaults copy];
    if (outCommit) *outCommit = [commit copy];

    return view;
}

// Modal preference window. Hosts an NSTabView with four tabs matching the
// Windows HexEditor reference (Start Layout, Startup, Colors, Font). Apply,
// Reset, OK, Cancel apply across all tabs at once. Reset only updates the
// in-dialog state — the user must still click Apply or OK for changes to
// land in NSUserDefaults.
static void presentOptionsDialog()
{
    @autoreleasepool {
        // ---- Layout constants ----
        const CGFloat windowWidth = 520.0;
        const CGFloat windowHeight = 360.0;
        const CGFloat innerMargin = 20.0;
        const CGFloat buttonRowHeight = 32.0;
        const CGFloat buttonHeight = 28.0;
        const CGFloat buttonGap = 12.0;
        const CGFloat tabViewBottomY = innerMargin + buttonRowHeight + 12.0;
        const CGFloat tabViewWidth = windowWidth - 2 * innerMargin;
        const CGFloat tabViewHeight = windowHeight - tabViewBottomY - innerMargin;

        // ---- Window ----
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, windowWidth, windowHeight)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.title = L(@"options.title");
        window.releasedWhenClosed = NO;
        window.accessibilityIdentifier = @"hex-editor.options.window";
        [window center];

        // NSColorPanel is shared system-wide and persists its last picker
        // mode across launches. Two pitfalls:
        // 1. Gray Sliders mode locks the user to shades of black.
        // 2. Wheel mode rendering is governed by the current colour's
        //    brightness component — picking a black colour shows a fully
        //    black wheel, with the only visible affordance being a
        //    brightness slider on the side (easy to miss).
        // Color Sliders mode dodges both: three labelled R/G/B sliders
        // (with numeric inputs) make every component visibly editable
        // even when the starting colour is black. Force this mode each
        // time the dialog opens; we don't restore the previous mode on
        // close — Color Sliders is a sensible default for any caller.
        [NSColorPanel sharedColorPanel].mode = NSColorPanelModeRGB;
        [NSColorPanel sharedColorPanel].showsAlpha = YES;

        NSView *content = window.contentView;

        // ---- Tab view ----
        NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(innerMargin, tabViewBottomY, tabViewWidth, tabViewHeight)];
        tabView.accessibilityIdentifier = @"hex-editor.options.tabView";
        [content addSubview:tabView];

        // Tab content size = tab view's interior. NSTabView reserves room
        // for the tab bar at the top; the content rect is what we need.
        const NSSize tabContentSize = [tabView contentRect].size;

        // Start Layout tab — fully implemented.
        void (^startLayoutApply)(void) = nil;
        void (^startLayoutCommit)(void) = nil;
        NSView *startLayoutView = makeStartLayoutTab(tabContentSize,
                                                      &startLayoutApply,
                                                      &startLayoutCommit);
        NSTabViewItem *startLayoutItem = [[NSTabViewItem alloc] initWithIdentifier:@"startLayout"];
        startLayoutItem.label = L(@"options.tab.startLayout");
        startLayoutItem.view = startLayoutView;
        [tabView addTabViewItem:startLayoutItem];

        // Startup tab — fully implemented.
        void (^startupApply)(void) = nil;
        void (^startupCommit)(void) = nil;
        NSView *startupView = makeStartupTab(tabContentSize, &startupApply, &startupCommit);
        NSTabViewItem *startupItem = [[NSTabViewItem alloc] initWithIdentifier:@"startup"];
        startupItem.label = L(@"options.tab.startup");
        startupItem.view = startupView;
        [tabView addTabViewItem:startupItem];

        // Colors tab — fully implemented.
        void (^colorsApply)(void) = nil;
        void (^colorsCommit)(void) = nil;
        NSView *colorsView = makeColorsTab(tabContentSize, &colorsApply, &colorsCommit);
        NSTabViewItem *colorsItem = [[NSTabViewItem alloc] initWithIdentifier:@"colors"];
        colorsItem.label = L(@"options.tab.colors");
        colorsItem.view = colorsView;
        [tabView addTabViewItem:colorsItem];

        // Font tab — fully implemented.
        void (^fontApply)(void) = nil;
        void (^fontCommit)(void) = nil;
        NSView *fontView = makeFontTab(tabContentSize, &fontApply, &fontCommit);
        NSTabViewItem *fontItem = [[NSTabViewItem alloc] initWithIdentifier:@"font"];
        fontItem.label = L(@"options.tab.font");
        fontItem.view = fontView;
        [tabView addTabViewItem:fontItem];

        // ---- Bottom button row: [Reset] .......... [Cancel] [Apply] [OK] ----
        // Right-anchored stack: OK is the rightmost (and the default action),
        // Apply sits to its left and applies values without closing the window,
        // Cancel sits to Apply's left, Reset is left-anchored at the opposite edge.
        // OK rather than "Save" — this is a hex editor and "Save" would imply
        // saving the document.
        HexOptionsButtonTarget *target = [[HexOptionsButtonTarget alloc] init];
        const CGFloat buttonY = innerMargin + (buttonRowHeight - buttonHeight) / 2.0;

        NSButton *okBtn = [NSButton buttonWithTitle:L(@"button.ok")
                                             target:target
                                             action:@selector(hexOptionsOk:)];
        okBtn.keyEquivalent = @"\r";   // Return triggers OK
        okBtn.bezelStyle = NSBezelStyleRounded;
        okBtn.accessibilityIdentifier = @"hex-editor.options.button.ok";
        [okBtn sizeToFit];
        const CGFloat okWidth = std::max<CGFloat>(NSWidth(okBtn.frame), 90.0);
        okBtn.frame = NSMakeRect(windowWidth - innerMargin - okWidth, buttonY, okWidth, buttonHeight);
        [content addSubview:okBtn];

        NSButton *applyBtn = [NSButton buttonWithTitle:L(@"options.button.apply")
                                                target:target
                                                action:@selector(hexOptionsApply:)];
        applyBtn.bezelStyle = NSBezelStyleRounded;
        applyBtn.accessibilityIdentifier = @"hex-editor.options.button.apply";
        [applyBtn sizeToFit];
        const CGFloat applyWidth = std::max<CGFloat>(NSWidth(applyBtn.frame), 90.0);
        applyBtn.frame = NSMakeRect(NSMinX(okBtn.frame) - buttonGap - applyWidth, buttonY, applyWidth, buttonHeight);
        [content addSubview:applyBtn];

        NSButton *cancelBtn = [NSButton buttonWithTitle:L(@"button.cancel")
                                                 target:target
                                                 action:@selector(hexOptionsCancel:)];
        cancelBtn.keyEquivalent = @"\e";   // Escape triggers Cancel
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        cancelBtn.accessibilityIdentifier = @"hex-editor.options.button.cancel";
        [cancelBtn sizeToFit];
        const CGFloat cancelWidth = std::max<CGFloat>(NSWidth(cancelBtn.frame), 90.0);
        cancelBtn.frame = NSMakeRect(NSMinX(applyBtn.frame) - buttonGap - cancelWidth, buttonY, cancelWidth, buttonHeight);
        [content addSubview:cancelBtn];

        NSButton *resetBtn = [NSButton buttonWithTitle:L(@"options.button.reset")
                                                target:target
                                                action:@selector(hexOptionsReset:)];
        resetBtn.bezelStyle = NSBezelStyleRounded;
        resetBtn.accessibilityIdentifier = @"hex-editor.options.button.reset";
        [resetBtn sizeToFit];
        const CGFloat resetWidth = NSWidth(resetBtn.frame);
        resetBtn.frame = NSMakeRect(innerMargin, buttonY, resetWidth, buttonHeight);
        [content addSubview:resetBtn];

        window.defaultButtonCell = okBtn.cell;

        // Aggregate commit across all tabs; Reset is scoped to the visible
        // tab only. Apply (loops the modal) and OK (exits) share the same
        // commit. Reset rewrites only the active tab's dialog UI to factory
        // defaults but does NOT touch the saved globals — Cancel after Reset
        // leaves the user's prior state intact. Tab-scoped Reset matches
        // user expectation (the visible tab is "the thing being reset");
        // resetting all tabs at once would silently nuke prefs the user
        // can't see (e.g. clicking Reset on Colors used to wipe Startup's
        // extension list).
        NSDictionary<NSString *, void (^)(void)> *applyByTab = @{
            @"startLayout": startLayoutApply ?: ^{},
            @"startup":     startupApply     ?: ^{},
            @"colors":      colorsApply      ?: ^{},
            @"font":        fontApply        ?: ^{},
        };
        NSArray<void (^)(void)> *commitBlocks = @[
            startLayoutCommit ?: ^{},
            startupCommit ?: ^{},
            colorsCommit ?: ^{},
            fontCommit ?: ^{},
        ];
        void (^applyDefaultsForActiveTab)(void) = ^{
            NSString *active = tabView.selectedTabViewItem.identifier;
            void (^block)(void) = applyByTab[active];
            if (block) block();
        };
        void (^commitAll)(void) = ^{
            for (void (^block)(void) in commitBlocks) block();
            if (hexTableView != nil) {
                applyHexViewMode();
            }
        };

        // ---- Modal session (loop on Reset / Apply) ----
        while (true) {
            const NSModalResponse response = [NSApp runModalForWindow:window];
            if (response == kHexOptionsResultReset) {
                applyDefaultsForActiveTab();
                continue;
            }
            if (response == kHexOptionsResultApply) {
                commitAll();
                continue;
            }
            if (response != kHexOptionsResultOk) {
                [window orderOut:nil];
                return;
            }
            break;
        }
        [window orderOut:nil];
        commitAll();
    }
}

static void optionsPreview()
{
    presentOptionsDialog();
}

extern "C" NPP_EXPORT void setInfo(NppData data)
{
    nppData = data;

    // Test hook: a sandboxed XCUI runner cannot reach `~/Library/Preferences/` to clear
    // the host-side plist between runs (its `UserDefaults(suiteName:)` writes go into the
    // runner's own container). Honour `--reset-hex-prefs` on the host's argv so the test
    // bundle can request a clean slate without giving up persistence semantics in normal use.
    NSArray<NSString *> *launchArgs = [[NSProcessInfo processInfo] arguments];
    if ([launchArgs containsObject:@"--reset-hex-prefs"]) {
        [hexPrefs() removePersistentDomainForName:HEX_PREFS_SUITE];
        [hexPrefs() synchronize];
    }
    loadHexPrefs();


    // Plugin menu entries are C strings (FuncItem._itemName is a fixed char[]).
    // We pull the localized title via L() and copy its UTF8 form. Notepad++ reads
    // these once during plugin load, so the language is locked at startup.
    strlcpy(funcItem[0]._itemName, [L(@"menu.plugin.viewInHex") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[0]._pFunc = toggleHexPreview;
    funcItem[0]._init2Check = false;
    funcItem[0]._pShKey = &hexShortcut;

    strlcpy(funcItem[1]._itemName, [L(@"menu.plugin.compareHex") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[1]._pFunc = compareHexPreview;
    funcItem[1]._init2Check = false;
    funcItem[1]._pShKey = nullptr;

    strlcpy(funcItem[2]._itemName, [L(@"menu.plugin.clearCompareResult") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[2]._pFunc = clearComparePreview;
    funcItem[2]._init2Check = false;
    funcItem[2]._pShKey = nullptr;

    strlcpy(funcItem[3]._itemName, [L(@"menu.plugin.insertColumns") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[3]._pFunc = insertColumnsPreview;
    funcItem[3]._init2Check = false;
    funcItem[3]._pShKey = nullptr;

    strlcpy(funcItem[4]._itemName, [L(@"menu.plugin.patternReplace") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[4]._pFunc = patternReplacePreview;
    funcItem[4]._init2Check = false;
    funcItem[4]._pShKey = nullptr;

    strlcpy(funcItem[5]._itemName, [L(@"menu.plugin.options") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[5]._pFunc = optionsPreview;
    funcItem[5]._init2Check = false;
    funcItem[5]._pShKey = nullptr;

    strlcpy(funcItem[6]._itemName, [L(@"menu.plugin.help") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[6]._pFunc = showAbout;
    funcItem[6]._init2Check = false;
    funcItem[6]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName()
{
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF)
{
    *nbF = NB_FUNC;
    return funcItem;
}

// Auto-engage check: consult the user's Startup-tab prefs against the
// currently active buffer and open the hex view if it matches. Safe to
// call repeatedly — early-outs when a hex view is already showing or no
// rules are configured. Used from both NPPN_BUFFERACTIVATED (user
// switched tabs) and NPPN_READY (NPP just finished restoring its
// session and the active buffer was set up before our plugin loaded, so
// we never saw its activation event).
static void tryAutoEngageHexView()
{
    if (previewBufferId != 0) return;
    if (g_autoExtensions.length == 0 && g_autoControlPercent <= 0) return;
    const uintptr_t bufferId = getCurrentBufferId();
    const NppHandle handle = getCurrentScintilla();
    bool shouldEngage = false;
    if (g_autoExtensions.length > 0) {
        NSString *path = getFullPathFromBufferId(bufferId);
        if (autoExtensionMatches(path)) shouldEngage = true;
    }
    if (!shouldEngage && g_autoControlPercent > 0) {
        shouldEngage = autoControlCharThresholdReached(handle, g_autoControlPercent);
    }
    if (shouldEngage) {
        showHexPreview();
    }
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode)
{
    const NppHandle notificationHandle = reinterpret_cast<NppHandle>(notifyCode->nmhdr.hwndFrom);
    if (notifyCode->nmhdr.code == NPPN_FILEBEFORECLOSE || notifyCode->nmhdr.code == NPPN_FILECLOSED) {
        // The buffer being closed should drop its hex-view intent so a
        // freshly-opened file doesn't unexpectedly come up in hex view if
        // it happens to land on the same memory address.
        clearHexIntent(reinterpret_cast<uintptr_t>(notificationHandle));
        if (previewBufferId != 0) {
            hideHexPreview();
            return;
        }
    }

    if (previewBufferId != 0 &&
        notifyCode->nmhdr.code == NPPN_BUFFERACTIVATED &&
        getCurrentBufferId() != previewBufferId) {
        hideHexPreview();
        // Don't clear intent for the previously-active buffer — the user
        // may switch back to it, in which case the intent restore below
        // re-engages hex view there. Fall through to the engage check.
    }

    // NPP-Mac restores its session BEFORE plugins load (see AppDelegate.mm:
    // session restore at ~line 138, plugin loadPlugins+fireReady at ~line
    // 158). The buffer-activation events for restored buffers fire too
    // early for our plugin to hear them. NPPN_READY is fired AFTER both,
    // so it's the canonical "everything is set up; check the active
    // buffer now" hook for first-launch behaviour.
    if (notifyCode->nmhdr.code == NPPN_READY ||
        notifyCode->nmhdr.code == NPPN_BUFFERACTIVATED) {
        // Per-buffer user intent takes precedence over the auto-engage
        // heuristic: a tab the user previously engaged should come back
        // in hex view even if its extension / content density wouldn't
        // otherwise auto-engage.
        const uintptr_t currentBuf = getCurrentBufferId();
        if (currentBuf != 0 && hasHexIntent(currentBuf) && previewBufferId == 0) {
            showHexPreview();
        } else {
            tryAutoEngageHexView();
        }
    }

    if (previewBufferId != 0 &&
        (notificationHandle == nppData._scintillaMainHandle || notificationHandle == nppData._scintillaSecondHandle) &&
        notifyCode->nmhdr.code == SCN_MODIFIED &&
        (notifyCode->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) != 0 &&
        hexTableView &&
        isPreviewBufferActive() &&
        !suppressModificationRefresh) {
        // The Scintilla we're already bound to just mutated. Drop the page
        // cache instead of rebuilding the source so consecutive byte edits
        // don't allocate two unique_ptrs per keypress.
        invalidateHexBuffer();
        clampActiveCursor();
        refreshVisibleHexTables();
    }

    if (notifyCode->nmhdr.code == NPPN_SHUTDOWN) {
        // If we hold an outstanding pasteboard promise (the user did Cmd-C
        // in the hex view and didn't paste yet — or pasted only into apps
        // that read the type via pbs IPC, leaving us as the data provider),
        // the bytes vanish when our process dies. Office and Word handle
        // this by asking the user at quit; we follow the same pattern.
        // Trivial-size snapshots (≤ 16 MB) materialize silently — no user
        // friction for small clipboards. Larger ones get a prompt.
        materializeHexClipboardOnQuitIfNeeded();

        hideHexPreview();
        hexRootView = nil;
        hexTableView = nil;
        hexStatusLabel = nil;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t)
{
    return TRUE;
}
