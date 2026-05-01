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
#include <set>
#include <sstream>
#include <string>
#include <vector>

static const char *PLUGIN_NAME = "HEX-Editor";
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
            // Plugin menu (Plugins > HEX-Editor > …)
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
            @"app.title":                        @"HEX-Editor",
            @"app.titleMac":                     @"HEX-Editor for macOS",
            @"app.titleCompare":                 @"HEX-Editor Compare",

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
            @"status.showingTruncated":          @"Showing %1$zu of %2$zu bytes. Preview is truncated for responsiveness.",
            @"status.rectangle":                 @"Rectangle: %1$lu × %2$lu (%3$lu bytes)",

            // Rectangular paste error dialogs (strict shape-match)
            @"paste.rect.errorAddressSource":      @"Address selections cannot be pasted as bytes. Copy a hex or ASCII rectangle and try again.",
            @"paste.rect.errorNeedsRectDestination": @"Destination must be a rectangular selection of %1$lu × %2$lu bytes. Option-drag (or Shift+Option-drag, per Options) to create one.",
            @"paste.rect.errorShapeMismatch":      @"Destination is the wrong size — must be %1$lu bytes wide and %2$lu bytes high.",

            // Pattern Replace — rectangular variant
            @"patternReplace.messageRect":         @"Fill the current %1$lu × %2$lu rectangle with a repeating hex pattern.\nThe pattern restarts at the first byte of each row.\n\nPattern: hex bytes only (e.g. 0xFF or DE AD).",
            @"patternReplace.summaryRect":         @"Filled %1$lu × %2$lu rectangle (%3$lu bytes) with the pattern.",

            // About / help dialog
            @"about.body":                       @"Native macOS port of the Notepad++ HEX-Editor plugin. Provides an inline hex table with direct byte editing, selection, bookmarks, find/replace, compare, and view-mode switching.",
            // Embedded fallback when no .strings file is loaded — distinct from
            // any shipped tag so the cascade XCTest can detect this state.
            @"about.localeTag":                  @"Strings: (embedded)",

            // Generic error path used when toggling between Scintilla / hex view
            @"editor.noActiveBuffer":            @"No active editor buffer is available.",
            @"editor.noActiveView":              @"Could not find the active editor view to replace.",

            // Column headers in the hex table
            @"table.header.offset":              @"Offset",
            @"table.header.ascii":               @"ASCII",

            // Options dialog
            @"options.title":                    @"HEX-Editor Options",
            @"options.message":                  @"Plugin-wide preferences. Reset restores the defaults shown below; click Save to apply.",
            @"options.button.save":              @"Save",
            @"options.button.reset":             @"Reset to Defaults",
            @"options.rectModifier.label":       @"Modifier key for rectangular (block) selection drag:",
            @"options.rectModifier.option":      @"Option (matches Scintilla / Windows hex editor)",
            @"options.rectModifier.shiftOption": @"Shift+Option (matches VS Code)",
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
static NSString *L(NSString *key)
{
    for (NSDictionary<NSString *, NSString *> *layer in hexActiveStringsChain()) {
        NSString *value = layer[key];
        if (value != nil && value.length > 0) {
            return value;
        }
    }
    NSString *fallback = hexEnglishDefaults()[key];
    return fallback != nil ? fallback : key;
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
static const size_t PREVIEW_LIMIT = 1024 * 1024;
static const CGFloat HEX_TABLE_HEIGHT = 640.0;
static const CGFloat HEX_STATUS_HEIGHT = 24.0;
static const CGFloat HEX_FALLBACK_FONT_SIZE = 10.0;
static const CGFloat HEX_CELL_HORIZONTAL_PADDING = 2.0;
static const CGFloat HEX_MID_BYTE_SEPARATOR_WIDTH = 5.0;
static const CGFloat HEX_ASCII_SEPARATOR_WIDTH = 8.0;
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
static NSString *const HEX_PREF_RECT_MODIFIER = @"rectangularSelectionModifier";

// Pref values for HEX_PREF_RECT_MODIFIER. Stored as strings so the on-disk plist is
// readable / hand-editable. The default (Option) matches Scintilla's Alt-drag convention
// inherited from the Windows hex editor; some users prefer Shift+Option to match
// VS Code, hence the option.
static NSString *const HEX_RECT_MOD_OPTION = @"Option";
static NSString *const HEX_RECT_MOD_SHIFT_OPTION = @"ShiftOption";
static NSString *const HEX_RECT_MOD_DEFAULT = @"Option";

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
static NSString *g_rectModifier = HEX_RECT_MOD_DEFAULT;

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

// Translates the stored rect-modifier string into the NSEventModifierFlags mask the
// mouse handler compares against. Unknown stored values fall back to the default
// (Option) — robust against future renames or hand-edited plists.
static NSEventModifierFlags rectModifierFlagsFor(NSString *modifier)
{
    if ([modifier isEqualToString:HEX_RECT_MOD_SHIFT_OPTION]) {
        return NSEventModifierFlagShift | NSEventModifierFlagOption;
    }
    return NSEventModifierFlagOption;
}

static NSEventModifierFlags currentRectModifierFlags()
{
    return rectModifierFlagsFor(g_rectModifier);
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
    g_littleEndian = (bpc > 1) ? hexPrefBool(HEX_PREF_LITTLE_ENDIAN, false) : false;
    g_addressWidth = std::clamp(
        hexPrefInt(HEX_PREF_ADDRESS_WIDTH, HEX_DEFAULT_ADDRESS_WIDTH),
        HEX_MIN_ADDRESS_WIDTH,
        HEX_MAX_ADDRESS_WIDTH);
    const int columnsLimit = columnsLimitForBytesPerCell(g_bytesPerCell);
    int columns = hexPrefInt(HEX_PREF_COLUMNS, defaultColumnsForBytesPerCell(g_bytesPerCell));
    g_columns = std::clamp(columns, 1, columnsLimit);
    g_findMatchCase = hexPrefBool(HEX_PREF_FIND_MATCH_CASE, true);
    g_findWrap = hexPrefBool(HEX_PREF_FIND_WRAP, true);
    NSString *rectMod = hexPrefString(HEX_PREF_RECT_MODIFIER, HEX_RECT_MOD_DEFAULT);
    g_rectModifier = [rectMod isEqualToString:HEX_RECT_MOD_SHIFT_OPTION]
        ? HEX_RECT_MOD_SHIFT_OPTION
        : HEX_RECT_MOD_OPTION;
}

static void saveHexPrefs()
{
    hexPrefSetInt(HEX_PREF_BYTES_PER_CELL, g_bytesPerCell);
    hexPrefSetBool(HEX_PREF_NOTATION_BINARY, g_notation == hexedit::CellNotation::Binary);
    hexPrefSetBool(HEX_PREF_LITTLE_ENDIAN, g_littleEndian);
    hexPrefSetInt(HEX_PREF_ADDRESS_WIDTH, g_addressWidth);
    hexPrefSetInt(HEX_PREF_COLUMNS, g_columns);
    hexPrefSetString(HEX_PREF_RECT_MODIFIER, g_rectModifier);
}

static FuncItem funcItem[NB_FUNC];
static ShortcutKey hexShortcut = { false, true, true, true, 'H' };
static NppData nppData = {};
static NSView *hexRootView = nil;
static NSTableView *hexTableView = nil;
static NSTextField *hexStatusLabel = nil;
static NSView *hexEditorView = nil;
static NSView *hiddenScintillaView = nil;
static std::vector<uint8_t> previewBytes;
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
// g_rectOriginIsAddress = drag started in the offset column, in which case the rect
// snaps to whole rows (full bytesPerRow width). g_rectOriginField is the pane the
// drag began in (Hex or Ascii) and is later used by the copy/paste matrix in chunk 3
// to tag the clipboard payload with kind = Bytes / Ascii / Addresses.
static hexedit::RectSelection g_rectSelection;
static bool g_rectActive = false;
static bool g_isSelectingRect = false;
static size_t g_rectAnchorOffset = 0;
static HexCursorField g_rectOriginField = HexCursorField::Hex;
static bool g_rectOriginIsAddress = false;

static void zoomHexFont(NSInteger delta);
static void resetHexFontZoom();
static void refreshVisibleHexTables();
static NSFont *hexTableFont();
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
    // the user changes columns). rectOriginPane is "Hex" / "Ascii" / "Address" so chunk 3
    // tests can confirm the source-pane tag will travel through to the clipboard.
    NSString *rectOriginPane = g_rectOriginIsAddress
        ? @"Address"
        : (g_rectOriginField == HexCursorField::Ascii ? @"Ascii" : @"Hex");
    return [NSString stringWithFormat:
            @"offset=%zu;selStart=%zu;selEnd=%zu;hasSelection=%d;statusH=%.1f;statusFontH=%.1f"
            @";sciSelStart=%lld;sciSelEnd=%lld;sciCaret=%lld;preferredLanguages=%@;userPrefs=%@"
            @";rectActive=%d;rectOrigin=%zu;rectWidth=%zu;rectHeight=%zu;rectBpr=%zu;rectOriginPane=%@",
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
            rectOriginPane];
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
    NSInteger rows = static_cast<NSInteger>((previewBytes.size() + bpr - 1) / bpr);
    if (previewBytes.size() == previewTotalLength && (previewBytes.empty() || previewBytes.size() % bpr == 0)) {
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
        return [NSString stringWithFormat:@"%0*zx", g_addressWidth, rowOffset];
    }

    if ([identifier isEqualToString:@"ascii"]) {
        std::string ascii;
        ascii.reserve(static_cast<size_t>(bytesPerRow));
        for (int index = 0; index < bytesPerRow; ++index) {
            const size_t byteIndex = rowOffset + static_cast<size_t>(index);
            if (byteIndex < previewBytes.size()) {
                const uint8_t value = previewBytes[byteIndex];
                ascii.push_back(std::isprint(value) ? static_cast<char>(value) : '.');
            } else {
                ascii.push_back(' ');
            }
        }
        return [NSString stringWithUTF8String:ascii.c_str()];
    }

    if ([identifier isEqualToString:@"midspacer"] || [identifier isEqualToString:@"spacer"]) {
        return @"";
    }

    if ([identifier hasPrefix:@"cell"]) {
        const NSInteger cellIndex = [[identifier substringFromIndex:4] integerValue];
        const hexedit::ViewMode mode = currentViewMode();
        const size_t firstByte = rowOffset + static_cast<size_t>(cellIndex) * static_cast<size_t>(mode.bytesPerCell);
        if (firstByte >= previewBytes.size()) {
            return @"";
        }
        const size_t available = std::min(static_cast<size_t>(mode.bytesPerCell), previewBytes.size() - firstByte);
        std::string formatted = hexedit::formatCell(previewBytes.data() + firstByte, available, mode);
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
    textCell.drawsBackground = NO;
    textCell.backgroundColor = nil;
    textCell.textColor = [NSColor labelColor];

    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"offset"] && isBookmarkedRow(static_cast<size_t>(row))) {
        textCell.drawsBackground = YES;
        textCell.backgroundColor = [NSColor systemRedColor];
        textCell.textColor = [NSColor whiteColor];
    } else if ([identifier hasPrefix:@"cell"] && !g_compareDiffs.empty()) {
        const NSInteger cellIdx = [[identifier substringFromIndex:4] integerValue];
        if (compareDiffMaskCellHasDiff(row, cellIdx)) {
            textCell.drawsBackground = YES;
            textCell.backgroundColor = hexCompareDiffColor();
            textCell.textColor = [NSColor whiteColor];
        }
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return NO;
}
@end

static HexTableDataSource *hexTableDataSource = nil;

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

    if (!isVisibleEditableOffset(activeByteOffset)) {
        return;
    }

    const size_t caretBpr = static_cast<size_t>(currentBytesPerRow());
    const bool drawAsciiCaretAtLineEnd = hasByteSelection() &&
        activeCursorField == HexCursorField::Ascii &&
        selectedByteEnd > selectedByteStart &&
        selectedByteEnd == activeByteOffset &&
        (selectedByteEnd % caretBpr) == 0;
    const size_t caretByteOffset = drawAsciiCaretAtLineEnd ? selectedByteEnd - 1 : activeByteOffset;
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
    } else {
        const NSInteger tableColumn = [self columnWithIdentifier:@"ascii"];
        if (tableColumn < 0) {
            return;
        }

        cellFrame = [self frameOfCellAtColumn:tableColumn row:row];
        const CGFloat charWidth = monospacedGlyphWidth(font);
        const size_t asciiColumnIndex = drawAsciiCaretAtLineEnd ? caretBpr : (caretByteOffset % caretBpr);
        caretX = asciiGlyphLeft(self, tableColumn, row) + static_cast<CGFloat>(asciiColumnIndex) * charWidth;
    }

    NSRect caretRect = NSMakeRect(caretX, NSMinY(cellFrame) + 2.0, HEX_CARET_WIDTH, std::max<CGFloat>(NSHeight(cellFrame) - 4.0, 1.0));
    [[NSColor selectedContentBackgroundColor] setFill];
    NSRectFill(caretRect);
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
    NSMenuItem *cutItem = [menu addItemWithTitle:L(@"menu.context.cut") action:@selector(hexCut:) keyEquivalent:@""];
    cutItem.target = self;
    NSMenuItem *copyItem = [menu addItemWithTitle:L(@"menu.context.copy") action:@selector(hexCopy:) keyEquivalent:@""];
    copyItem.target = self;
    NSMenuItem *pasteItem = [menu addItemWithTitle:L(@"menu.context.paste") action:@selector(hexPaste:) keyEquivalent:@""];
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
        if (hasRectSelection()) {
            return YES;
        }
        size_t offset = 0;
        size_t byteCount = 0;
        selectedOrCurrentRange(&offset, &byteCount);
        return byteCount > 0;
    }
    if (action == @selector(paste:) || action == @selector(hexPaste:) || action == @selector(hexPasteBinary:)) {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        return [pasteboard dataForType:NSPasteboardTypeString] != nil ||
            [pasteboard dataForType:@"public.data"] != nil ||
            [pasteboard dataForType:kHexRectPasteboardType] != nil ||
            [pasteboard stringForType:NSPasteboardTypeString] != nil;
    }
    if (action == @selector(selectAll:)) {
        return !previewBytes.empty();
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
    activeByteOffset = selectedByteEnd;
    activeHexNibble = 0;
    clampActiveCursor();
    [self setNeedsDisplay:YES];
}

// Modifier-mask comparison helper. The user may choose between Option and Shift+Option
// for the rectangular drag modifier; we ignore Caps Lock and any other irrelevant flags
// that macOS sometimes pipes through, so the comparison is always against the relevant
// command/option/shift/control set.
- (BOOL)hexEvent:(NSEvent *)event matchesRectModifier:(NSEventModifierFlags)rectFlags
{
    const NSEventModifierFlags relevant = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    return relevant == rectFlags;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint scrollOrigin = [self currentScrollOrigin];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = [self rowAtPoint:point];
    const NSInteger column = [self columnAtPoint:point];

    const NSEventModifierFlags rectFlags = currentRectModifierFlags();
    const BOOL isRectModifier = [self hexEvent:event matchesRectModifier:rectFlags];

    if (row >= 0 && column >= 0) {
        NSTableColumn *tableColumn = self.tableColumns[column];
        NSString *identifier = tableColumn.identifier;

        if ([identifier isEqualToString:@"offset"]) {
            // Address column: bare click toggles a bookmark; rect-modifier+click starts
            // a row-granular rectangular selection (full row width).
            if (isRectModifier && previewTotalLength > 0) {
                clearAllByteSelections();
                const size_t bpr = static_cast<size_t>(currentBytesPerRow());
                const size_t rowStartOffset = static_cast<size_t>(row) * bpr;
                g_rectAnchorOffset = rowStartOffset;
                g_rectOriginIsAddress = true;
                g_rectOriginField = HexCursorField::Hex;
                g_isSelectingRect = true;
                updateRectSelectionToOffset(rowStartOffset + bpr - 1);
                [self.window makeFirstResponder:self];
                [self reloadDataPreservingScrollOrigin:scrollOrigin];
                return;
            }
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
                g_rectOriginIsAddress = false;
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

        if (g_rectOriginIsAddress) {
            // Row-only: track which row the pointer is over and rebuild the rect to
            // span anchor's row..pointer's row, full row width.
            if (row >= 0) {
                const size_t bpr = static_cast<size_t>(currentBytesPerRow());
                const size_t rowStartOffset = static_cast<size_t>(row) * bpr;
                updateRectSelectionToOffset(rowStartOffset + bpr - 1);
            }
            return;
        }

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
    const NSEventModifierFlags rectFlags = currentRectModifierFlags();
    const NSEventModifierFlags rectExtendFlags = rectFlags | NSEventModifierFlagShift;
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
            g_rectOriginIsAddress = false;
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
    const CGFloat fontSize = std::clamp(editorBaseFontSize + static_cast<CGFloat>(hexFontZoomDelta), HEX_MIN_FONT_SIZE, HEX_MAX_FONT_SIZE);
    return [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
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

// Semantic NSColor values throughout — they auto-flip in dark mode and follow the
// user's accent colour. Replaced four hardcoded calibratedRGB values whose previous
// contrast was correct only in light mode. The host (Notepad++ macOS) inherits dark
// mode via NSAppearance with no plugin-side toggle, so we follow suit.
static NSColor *hexCurrentLineColor()
{
    return [NSColor unemphasizedSelectedContentBackgroundColor];
}

static NSColor *hexSelectionColor()
{
    // 0.6 alpha keeps the byte text readable on top of the selection wash regardless
    // of accent colour intensity.
    return [[NSColor selectedContentBackgroundColor] colorWithAlphaComponent:0.6];
}

static NSColor *hexCurrentLineSelectionColor()
{
    // Lighter wash for "selected and on the current line" — the same accent colour
    // but a softer alpha so the row highlight underneath is still discernible.
    return [[NSColor selectedContentBackgroundColor] colorWithAlphaComponent:0.85];
}

static NSColor *hexCompareDiffColor()
{
    // System red adapts in dark mode; matching the bookmark highlight semantic.
    return [NSColor systemRedColor];
}

static CGFloat paddedTextWidth(NSString *text, NSFont *font)
{
    return textWidth(text, font) + HEX_CELL_HORIZONTAL_PADDING;
}

static CGFloat offsetColumnWidth(NSFont *font)
{
    const int width = std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(width) withString:@"0" startingAtIndex:0];
    // Measure against the localized header so wider translations (e.g. a future
    // "Adresse" / "Adresák" in some language) don't clip.
    return std::max(paddedTextWidth(sample, font), paddedTextWidth(L(@"table.header.offset"), font));
}

static CGFloat cellColumnWidth(NSFont *font, const hexedit::ViewMode &mode)
{
    const int digits = hexedit::digitsPerCell(mode);
    NSString *sample = [@"" stringByPaddingToLength:static_cast<NSUInteger>(std::max(digits, 1))
                                          withString:@"0"
                                     startingAtIndex:0];
    return std::max(paddedTextWidth(sample, font), paddedTextWidth(@"0F", font));
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
    return std::max(paddedTextWidth(sample, font), paddedTextWidth(L(@"table.header.ascii"), font));
}

static CGFloat tableContentWidth(NSFont *font)
{
    const hexedit::ViewMode mode = currentViewMode();
    const int cells = std::max(currentCellsPerRow(), 1);
    return offsetColumnWidth(font) + (static_cast<CGFloat>(cells) * cellColumnWidth(font, mode)) + HEX_MID_BYTE_SEPARATOR_WIDTH + HEX_ASCII_SEPARATOR_WIDTH + asciiColumnWidth(font);
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

static std::vector<uint8_t> readCurrentBuffer(size_t *totalLength)
{
    NppHandle editor = previewScintillaHandle ? previewScintillaHandle : getCurrentScintilla();
    if (!editor) {
        if (totalLength) {
            *totalLength = 0;
        }
        return {};
    }

    const intptr_t length = sci(editor, SCI_GETLENGTH);
    if (length <= 0) {
        if (totalLength) {
            *totalLength = 0;
        }
        return {};
    }

    const size_t byteCount = static_cast<size_t>(length);
    const size_t bytesToRead = std::min(byteCount, PREVIEW_LIMIT);
    std::vector<uint8_t> bytes;
    bytes.reserve(bytesToRead);

    for (size_t offset = 0; offset < bytesToRead; ++offset) {
        bytes.push_back(static_cast<uint8_t>(sci(editor, SCI_GETCHARAT, offset, 0) & 0xff));
    }

    if (totalLength) {
        *totalLength = byteCount;
    }

    return bytes;
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
    g_rectOriginIsAddress = false;
    g_rectOriginField = HexCursorField::Hex;
}

static void clearAllByteSelections()
{
    clearByteSelection();
    clearRectSelection();
}

// Build/update the rectangle from the stored anchor + a new endpoint. For an
// address-pane drag, both anchor and end are snapped to row boundaries so the rect
// always spans the full bytesPerRow width.
static void updateRectSelectionToOffset(size_t endOffset)
{
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
    if (bpr == 0) {
        return;
    }
    size_t anchor = g_rectAnchorOffset;
    size_t end = endOffset;

    if (g_rectOriginIsAddress) {
        const size_t anchorRowStart = (anchor / bpr) * bpr;
        const size_t endRowStart = (end / bpr) * bpr;
        anchor = anchorRowStart;
        end = endRowStart + (bpr - 1);
    }

    g_rectSelection = hexedit::makeRectSelection(anchor, end, bpr, previewTotalLength);
    g_rectActive = g_rectSelection.active();
    if (g_rectActive) {
        // Track the active cursor at the dragged-to corner so the caret indicator
        // stays under the user's pointer / arrow keys.
        activeByteOffset = std::min(end, previewTotalLength > 0 ? previewTotalLength - 1 : 0);
        activeHexNibble = 0;
        activeCursorField = g_rectOriginIsAddress ? HexCursorField::Hex : g_rectOriginField;
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
    activeByteOffset = std::min(upper, previewBytes.size());

    if (start != end) {
        selectedByteStart = std::min(lower, previewBytes.size());
        selectedByteEnd = std::min(upper, previewBytes.size());
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
    view.bytes = previewBytes.empty() ? nullptr : previewBytes.data();
    view.visibleByteCount = previewBytes.size();
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

    previewBytes = readCurrentBuffer(&previewTotalLength);
    clampActiveCursor();
    if (hexStatusLabel) {
        hexStatusLabel.stringValue = makeStatusText();
    }
    return true;
}

static void refreshHexViewFromScintilla(size_t preferredCursorOffset, NSPoint scrollOrigin)
{
    previewBytes = readCurrentBuffer(&previewTotalLength);
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

// Copy the active rectangular selection to the system pasteboard. Always emits the
// custom UTI (so paste-back into this plugin gets the exact shape) plus a public-text
// fallback for external apps. Source-pane chooses the kind tag and the text shape:
// Address-pane drag → row of address strings; ASCII-pane drag → ASCII per row;
// otherwise hex per row.
static bool copyRectToPasteboard()
{
    if (!hasRectSelection()) {
        return false;
    }
    HexRectClipboardKind kind = HexRectClipboardKind::Bytes;
    if (g_rectOriginIsAddress) {
        kind = HexRectClipboardKind::Addresses;
    } else if (g_rectOriginField == HexCursorField::Ascii) {
        kind = HexRectClipboardKind::Ascii;
    }

    std::vector<std::uint8_t> payloadBytes;
    if (kind != HexRectClipboardKind::Addresses) {
        hexedit::extractRectBytes(previewBytes.data(), previewBytes.size(),
                                   g_rectSelection, payloadBytes);
    }
    // Build the public-text fallback per kind so external apps see something useful.
    std::string text;
    if (kind == HexRectClipboardKind::Addresses) {
        // Address-column drag: one address string per selected row.
        const int addrWidth = std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH);
        const std::size_t firstRow = g_rectSelection.originOffset / g_rectSelection.bytesPerRow;
        for (std::size_t r = 0; r < g_rectSelection.height; ++r) {
            if (r > 0) text.push_back('\n');
            char buf[64];
            std::snprintf(buf, sizeof(buf), "%0*zx", addrWidth,
                          (firstRow + r) * g_rectSelection.bytesPerRow);
            text += buf;
        }
    } else if (kind == HexRectClipboardKind::Ascii) {
        text = hexedit::formatRectClipboardAscii(previewBytes.data(), g_rectSelection,
                                                  previewBytes.size());
    } else {
        text = hexedit::formatRectClipboardHex(previewBytes.data(), g_rectSelection,
                                                previewBytes.size());
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    NSString *textNS = [NSString stringWithUTF8String:text.c_str()];
    if (textNS != nil) {
        [pasteboard setString:textNS forType:NSPasteboardTypeString];
    }
    NSData *encoded = rectPayloadEncode(kind,
                                         static_cast<std::uint32_t>(g_rectSelection.width),
                                         static_cast<std::uint32_t>(g_rectSelection.height),
                                         payloadBytes.empty() ? nullptr : payloadBytes.data(),
                                         static_cast<std::uint32_t>(payloadBytes.size()));
    if (encoded != nil) {
        [pasteboard setData:encoded forType:kHexRectPasteboardType];
    }
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
    if (byteCount == 0 || offset >= previewBytes.size()) {
        return false;
    }

    byteCount = std::min(byteCount, previewBytes.size() - offset);
    const std::uint8_t *src = previewBytes.data() + offset;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];

    if (activeCursorField == HexCursorField::Ascii) {
        NSString *string = [[NSString alloc] initWithBytes:src length:byteCount encoding:NSUTF8StringEncoding];
        if (string == nil) {
            string = [[NSString alloc] initWithBytes:src length:byteCount encoding:NSWindowsCP1252StringEncoding];
        }
        if (string != nil) {
            [pasteboard setString:string forType:NSPasteboardTypeString];
        }
    } else {
        std::string hexText = hexedit::formatHexClipboardText(src, byteCount);
        NSString *string = [NSString stringWithUTF8String:hexText.c_str()];
        if (string != nil) {
            [pasteboard setString:string forType:NSPasteboardTypeString];
        }
    }

    NSData *bytes = [NSData dataWithBytes:src length:byteCount];
    [pasteboard setData:bytes forType:@"public.data"];
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
        std::vector<std::uint8_t> rectBytes;
        if (hexedit::extractRectBytes(previewBytes.data(), previewBytes.size(),
                                       g_rectSelection, rectBytes) && !rectBytes.empty()) {
            NSData *raw = [NSData dataWithBytes:rectBytes.data() length:rectBytes.size()];
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard setData:raw forType:@"public.data"];
        }
        return true;
    }

    size_t offset = 0;
    size_t byteCount = 0;
    selectedOrCurrentRange(&offset, &byteCount);
    if (byteCount == 0 || offset >= previewBytes.size()) {
        return false;
    }

    byteCount = std::min(byteCount, previewBytes.size() - offset);
    NSData *bytes = [NSData dataWithBytes:previewBytes.data() + offset length:byteCount];
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

    NSData *encoded = [pasteboard dataForType:kHexRectPasteboardType];
    BOOL haveStructured = rectPayloadDecode(encoded, &kind, &width, &height, &dataPtr, &dataLength);

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

    if (kind == HexRectClipboardKind::Addresses) {
        presentHexValidationError(L(@"paste.rect.errorAddressSource"));
        return true;
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

    if (dataPtr == nullptr || dataLength != width * height) {
        // Malformed payload (shouldn't happen for our own writes; could happen if
        // another plugin or version of us writes an invalid blob). Refuse rather
        // than guess.
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
    selectedByteEnd = previewBytes.size();
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
        NSString *currentHex = [NSString stringWithFormat:@"%0*zx", addrWidth, currentOffset];
        NSString *endHex = [NSString stringWithFormat:@"%0*zx", addrWidth, totalLength];
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
            startOffset = std::min(selectedByteStart + 1, previewBytes.size());
        } else {
            startOffset = std::min(activeByteOffset + 1, previewBytes.size());
        }
    } else {
        startOffset = hasByteSelection() ? selectedByteStart : activeByteOffset;
    }

    std::size_t found = 0;
    if (!hexedit::findBytePattern(previewBytes.data(), previewBytes.size(), pattern,
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
    std::vector<std::size_t> matches;
    std::size_t cursor = 0;
    while (cursor + findPattern.bytes.size() <= previewBytes.size()) {
        std::size_t at = 0;
        if (!hexedit::findBytePattern(previewBytes.data(), previewBytes.size(), findPattern,
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

    previewBytes = readCurrentBuffer(&previewTotalLength);
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

    activeByteOffset = std::min(selectedByteStart + replacePattern.bytes.size(), previewBytes.size());
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

    g_compareDiffs = hexedit::computeByteDiffs(previewBytes.data(), previewBytes.size(),
                                                otherBytes, otherLen);
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
    const std::size_t totalLength = previewBytes.size();
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

    previewBytes = readCurrentBuffer(&previewTotalLength);
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

static void configureTableColumn(NSTableView *tableView, NSString *identifier, NSString *title, CGFloat width, NSFont *font)
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = width;
    column.resizingMask = NSTableColumnNoResizing;

    NSTextFieldCell *cell = [[NSTextFieldCell alloc] init];
    cell.font = font;
    cell.lineBreakMode = NSLineBreakByClipping;
    cell.alignment = [identifier hasPrefix:@"cell"] ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    column.dataCell = cell;

    [tableView addTableColumn:column];
}

static void addHexCellColumns(NSTableView *table, NSFont *font)
{
    const hexedit::ViewMode mode = currentViewMode();
    const int cells = std::max(currentCellsPerRow(), 1);
    const CGFloat cellWidth = cellColumnWidth(font, mode);
    const int midpoint = cells / 2;  // 8 for bpc=1, 4 for bpc=2, 2 for bpc=4, 1 for bpc=8

    configureTableColumn(table, @"offset", L(@"table.header.offset"), offsetColumnWidth(font), font);
    for (int column = 0; column < cells; ++column) {
        const std::size_t firstByte = static_cast<std::size_t>(column) * static_cast<std::size_t>(g_bytesPerCell);
        configureTableColumn(
            table,
            [NSString stringWithFormat:@"cell%02d", column],
            [NSString stringWithFormat:@"%02zx", firstByte],
            cellWidth,
            font);
        if (cells >= 2 && column == midpoint - 1) {
            configureTableColumn(table, @"midspacer", @"", HEX_MID_BYTE_SEPARATOR_WIDTH, font);
        }
    }
    configureTableColumn(table, @"spacer", @"", HEX_ASCII_SEPARATOR_WIDTH, font);
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
    if (g_bytesPerCell == 1) {
        // Endianness is meaningless for single-byte cells (matches Windows isLittle reset
        // when bits drops back to HEX_BYTE).
        g_littleEndian = false;
    }
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
    for (NSTableColumn *column in table.tableColumns) {
        NSString *identifier = column.identifier;
        CGFloat width = 0.0;

        if ([identifier isEqualToString:@"offset"]) {
            width = offsetColumnWidth(font);
        } else if ([identifier isEqualToString:@"ascii"]) {
            width = asciiColumnWidth(font);
        } else if ([identifier isEqualToString:@"midspacer"]) {
            width = HEX_MID_BYTE_SEPARATOR_WIDTH;
        } else if ([identifier isEqualToString:@"spacer"]) {
            width = HEX_ASCII_SEPARATOR_WIDTH;
        } else {
            width = cellWidth;
        }

        column.width = width;
        column.minWidth = width;
        NSTextFieldCell *cell = static_cast<NSTextFieldCell *>(column.dataCell);
        cell.font = font;
    }

    if (statusLabel) {
        NSFont *labelFont = statusLabelFontFor(hexTableFont());
        statusLabel.font = labelFont;

        NSView *rootView = statusLabel.superview;
        if (rootView) {
            const CGFloat tableWidth = tableContainerWidth(font);
            NSRect rootFrame = rootView.frame;
            rootFrame.size.width = tableWidth;
            rootView.frame = rootFrame;

            // Status row height tracks the font's full ascender+descender extent,
            // plus a 4 pt margin above the row, so descender glyphs never clip.
            // The reserved status area is labelHeight + topMargin; the scroll view
            // gets whatever remains below it.
            const CGFloat labelHeight = textFrameHeightForFont(labelFont);
            const CGFloat topMargin = 4.0;
            const CGFloat statusAreaHeight = labelHeight + topMargin;
            statusLabel.frame = NSMakeRect(8, HEX_TABLE_HEIGHT - topMargin - labelHeight,
                                           tableWidth - 16, labelHeight);
            table.enclosingScrollView.frame = NSMakeRect(0, 0, tableWidth,
                                                         HEX_TABLE_HEIGHT - statusAreaHeight);
        }
    }
}

static NSView *createHexTableView(NSTableView **tableView, NSTextField **statusLabel)
{
    NSFont *font = hexTableFont();
    const CGFloat tableWidth = tableContainerWidth(font);
    NSView *rootView = [[HexTableContainerView alloc] initWithFrame:NSMakeRect(0, 0, tableWidth, HEX_TABLE_HEIGHT)];
    rootView.accessibilityIdentifier = kHexEditorRootAccessibilityID;

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
    if (previewBytes.empty()) {
        return L(@"status.empty");
    }

    NSString *baseText = nil;
    if (previewBytes.size() < previewTotalLength) {
        baseText = [NSString stringWithFormat:L(@"status.showingTruncated"),
            previewBytes.size(), previewTotalLength];
    } else {
        baseText = [NSString stringWithFormat:L(@"status.showing"), previewBytes.size()];
    }

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
    previewBytes = readCurrentBuffer(&previewTotalLength);
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
    updateHexMenuCheck(true);
}

static void toggleHexPreview()
{
    if (isHexViewActive() && isPreviewBufferActive()) {
        hideHexPreview();
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

        previewBytes.clear();
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
    NSString *body = [NSString stringWithFormat:@"%@\n\n%@",
                      L(@"about.body"), L(@"about.localeTag")];
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

// MARK: - Options dialog

// Modal sheet for plugin-wide preferences. Today there is one row (rectangular-selection
// modifier); the layout leaves room above each row for additional preferences to be
// appended later without restructuring. Reset only updates the in-dialog state — the
// user must still click Save for the change to land in NSUserDefaults.
static void presentOptionsDialog()
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(@"options.title");
        alert.informativeText = L(@"options.message");
        [alert addButtonWithTitle:L(@"options.button.save")];
        [alert addButtonWithTitle:L(@"options.button.reset")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        const CGFloat width = 380.0;
        const CGFloat labelHeight = 18.0;
        const CGFloat popupHeight = 26.0;
        const CGFloat sectionGap = 4.0;
        const CGFloat totalHeight = labelHeight + sectionGap + popupHeight;

        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

        CGFloat y = totalHeight - labelHeight;
        NSTextField *label = [NSTextField labelWithString:L(@"options.rectModifier.label")];
        label.frame = NSMakeRect(0, y, width, labelHeight);
        [accessory addSubview:label];

        y -= (popupHeight + sectionGap);
        NSPopUpButton *modifierPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, y, width, popupHeight)
                                                                 pullsDown:NO];
        modifierPopup.accessibilityIdentifier = @"hex-editor.options.rectMod.popup";
        [modifierPopup addItemWithTitle:L(@"options.rectModifier.option")];
        modifierPopup.lastItem.representedObject = HEX_RECT_MOD_OPTION;
        [modifierPopup addItemWithTitle:L(@"options.rectModifier.shiftOption")];
        modifierPopup.lastItem.representedObject = HEX_RECT_MOD_SHIFT_OPTION;
        [accessory addSubview:modifierPopup];

        // Block to apply a modifier value to the popup, shared by initial population and Reset.
        void (^applyModifier)(NSString *) = ^(NSString *modifier) {
            for (NSMenuItem *item in modifierPopup.itemArray) {
                if ([(NSString *)item.representedObject isEqualToString:modifier]) {
                    [modifierPopup selectItem:item];
                    return;
                }
            }
            [modifierPopup selectItemAtIndex:0];
        };
        applyModifier(g_rectModifier);

        alert.accessoryView = accessory;
        [alert.window setInitialFirstResponder:modifierPopup];

        // Loop on Reset so the user can preview the defaults before committing.
        // Save / Cancel exit the loop; Reset stays in it.
        while (true) {
            const NSModalResponse response = [alert runModal];
            if (response == NSAlertSecondButtonReturn) {
                applyModifier(HEX_RECT_MOD_DEFAULT);
                continue;
            }
            if (response != NSAlertFirstButtonReturn) {
                return;
            }
            break;
        }

        NSString *chosen = (NSString *)modifierPopup.selectedItem.representedObject ?: HEX_RECT_MOD_DEFAULT;
        if (![chosen isEqualToString:g_rectModifier]) {
            g_rectModifier = chosen;
            saveHexPrefs();
        }
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

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode)
{
    const NppHandle notificationHandle = reinterpret_cast<NppHandle>(notifyCode->nmhdr.hwndFrom);
    if (previewBufferId != 0 &&
        (notifyCode->nmhdr.code == NPPN_FILEBEFORECLOSE || notifyCode->nmhdr.code == NPPN_FILECLOSED)) {
        hideHexPreview();
        return;
    }

    if (previewBufferId != 0 &&
        notifyCode->nmhdr.code == NPPN_BUFFERACTIVATED &&
        getCurrentBufferId() != previewBufferId) {
        hideHexPreview();
        return;
    }

    if (previewBufferId != 0 &&
        (notificationHandle == nppData._scintillaMainHandle || notificationHandle == nppData._scintillaSecondHandle) &&
        notifyCode->nmhdr.code == SCN_MODIFIED &&
        (notifyCode->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) != 0 &&
        hexTableView &&
        isPreviewBufferActive() &&
        !suppressModificationRefresh) {
        previewBytes = readCurrentBuffer(&previewTotalLength);
        clampActiveCursor();
        refreshVisibleHexTables();
    }

    if (notifyCode->nmhdr.code == NPPN_SHUTDOWN) {
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
