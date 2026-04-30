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
static const int NB_FUNC = 6;

// MARK: - Localization
//
// User-facing strings are looked up by key against `Localizable.<lang>.strings`
// files installed alongside the dylib. If the user's preferred language file
// is missing or doesn't contain the key, the embedded English fallback is used,
// so the plugin always renders something — never a bare key.
//
// Language selection: the first hit from [NSLocale preferredLanguages] that
// has a corresponding strings file. Match is "exact (e.g. de-DE) → language
// code (e.g. de) → English fallback".
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

static NSDictionary<NSString *, NSString *> *hexActiveStrings()
{
    static NSDictionary<NSString *, NSString *> *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *raw in [NSLocale preferredLanguages]) {
            // Try the exact tag first ("de-DE"), then the bare language code ("de").
            NSDictionary *exact = hexLoadStringsForLanguage(raw);
            if (exact != nil && exact.count > 0) {
                cached = exact;
                return;
            }
            NSString *base = [raw componentsSeparatedByString:@"-"].firstObject;
            if (base != nil && ![base isEqualToString:raw]) {
                NSDictionary *fallback = hexLoadStringsForLanguage(base);
                if (fallback != nil && fallback.count > 0) {
                    cached = fallback;
                    return;
                }
            }
        }
        // Final fallback: explicit English file. If even that is missing the
        // embedded English defaults below carry the UI.
        cached = hexLoadStringsForLanguage(@"en");
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
            @"addressWidth.message":             @"Number of digits in the offset column (%d–%d).",
            @"addressWidth.invalidRange":        @"Only values between %d and %d possible.",

            // Columns dialog
            @"columns.title":                    @"Columns",
            @"columns.message":                  @"Number of cells per row (1–%d at the current bit width).",
            @"columns.invalidMaximum":           @"Maximum of %d bytes can be shown in a row.",

            // Go to Offset dialog
            @"goto.title":                       @"Go to Offset",
            @"goto.message":                     @"Enter a byte offset.\n  • Decimal: 1234\n  • Hex: 0x4A2 (or 0X4A2)\n  • Relative: +0x10 jumps forward, -100 jumps back\n\nCurrent: 0x%0*zx    End: 0x%0*zx",
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
            @"compare.errorReadFile":            @"Could not read %@: %@",
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
            @"insertColumns.message":            @"Insert a hex pattern into every row at a chosen column position. Each row grows by (count × %d) bytes; the column count grows by `count`.\n\nPattern: hex bytes only (e.g. 0x00 or DE AD).\nCount: 1 to %d at the current %d-bit grouping.\nPosition: 0 to %d (current column count).",
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
            @"insertColumns.summarySingularRows": @"Inserted %d column%@ across 1 row.",
            @"insertColumns.summaryPluralRows":   @"Inserted %d column%@ across %d rows.",

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
            @"status.showingTruncated":          @"Showing %zu of %zu bytes. Preview is truncated for responsiveness.",

            // About / help dialog
            @"about.body":                       @"Native macOS port of the Notepad++ HEX-Editor plugin. Provides an inline hex table with direct byte editing, selection, bookmarks, find/replace, compare, and view-mode switching.",

            // Generic error path used when toggling between Scintilla / hex view
            @"editor.noActiveBuffer":            @"No active editor buffer is available.",
            @"editor.noActiveView":              @"Could not find the active editor view to replace.",

            // Column headers in the hex table
            @"table.header.offset":              @"Offset",
            @"table.header.ascii":               @"ASCII",
        };
    });
    return defaults;
}

// Look up a localized string by key, falling back to the embedded English default
// if the active strings file doesn't contain the key. Returns the key itself only
// as a last-resort safety so a missing-from-everywhere key is visible during dev.
static NSString *L(NSString *key)
{
    NSDictionary *active = hexActiveStrings();
    NSString *value = active[key];
    if (value != nil && value.length > 0) {
        return value;
    }
    NSString *fallback = hexEnglishDefaults()[key];
    return fallback != nil ? fallback : key;
}

// Accessibility identifiers — must match the strings hard-coded in
// macos/ui-tests-xcode/Tests/HexEditorUITests.swift.
static NSString *const kHexEditorRootAccessibilityID = @"hex-editor.root";
static NSString *const kHexEditorTableAccessibilityID = @"hex-editor.table";
static NSString *const kHexEditorStatusAccessibilityID = @"hex-editor.status";
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
}

static void saveHexPrefs()
{
    hexPrefSetInt(HEX_PREF_BYTES_PER_CELL, g_bytesPerCell);
    hexPrefSetBool(HEX_PREF_NOTATION_BINARY, g_notation == hexedit::CellNotation::Binary);
    hexPrefSetBool(HEX_PREF_LITTLE_ENDIAN, g_littleEndian);
    hexPrefSetInt(HEX_PREF_ADDRESS_WIDTH, g_addressWidth);
    hexPrefSetInt(HEX_PREF_COLUMNS, g_columns);
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
static bool isSelectingBytes = false;
static size_t selectionAnchorByte = 0;

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
static size_t currentHighlightRow();
static void clearByteSelection();
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

@interface HexTableScrollView : NSScrollView
@end

@implementation HexTableScrollView
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
        if (!hasByteSelection() || selectedByteEnd <= rowStart || selectedByteStart >= rowEnd) {
            continue;
        }

        [(static_cast<size_t>(rowIndex) == highlightRow ? hexCurrentLineSelectionColor() : hexSelectionColor()) setFill];
        NSFont *font = hexTableFont();
        const CGFloat charWidth = monospacedGlyphWidth(font);
        const hexedit::ViewMode mode = currentViewMode();
        const int bpc = std::max(mode.bytesPerCell, 1);
        const int digitsPerByte = (mode.notation == hexedit::CellNotation::Binary) ? 8 : 2;
        const size_t selectedRowStart = std::max(selectedByteStart, rowStart);
        const size_t selectedRowEnd = std::min(selectedByteEnd, rowEnd);
        const size_t firstByteInRow = selectedRowStart % bpr;
        const size_t lastByteInRow = (selectedRowEnd - 1) % bpr;
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
    if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field] && !hasByteSelection()) {
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
        size_t offset = 0;
        size_t byteCount = 0;
        selectedOrCurrentRange(&offset, &byteCount);
        return byteCount > 0;
    }
    if (action == @selector(paste:) || action == @selector(hexPaste:) || action == @selector(hexPasteBinary:)) {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        return [pasteboard dataForType:NSPasteboardTypeString] != nil ||
            [pasteboard dataForType:@"public.data"] != nil ||
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

- (void)mouseDown:(NSEvent *)event
{
    NSPoint scrollOrigin = [self currentScrollOrigin];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = [self rowAtPoint:point];
    const NSInteger column = [self columnAtPoint:point];

    if (row >= 0 && column >= 0) {
        NSTableColumn *tableColumn = self.tableColumns[column];
        NSString *identifier = tableColumn.identifier;

        if ([identifier isEqualToString:@"offset"]) {
            toggleBookmarkRow(static_cast<size_t>(row));
            [self setNeedsDisplayInRect:[self rectOfRow:row]];
            return;
        }

        size_t byteOffset = 0;
        NSInteger nibble = 0;
        HexCursorField field = HexCursorField::Hex;
        if ([self byteOffsetAtPoint:point offset:&byteOffset nibble:&nibble field:&field]) {
            clearByteSelection();
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

    switch (character) {
    case NSBackspaceCharacter:
    case NSLeftArrowFunctionKey:
        clearByteSelection();
        writeBackCursor(hexedit::navigateLeft(currentCursor(), currentDocumentView(),
                                               currentViewMode(), currentBytesPerRow()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSRightArrowFunctionKey:
        clearByteSelection();
        writeBackCursor(hexedit::navigateRight(currentCursor(), currentDocumentView(),
                                                currentViewMode(), currentBytesPerRow()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSUpArrowFunctionKey:
        clearByteSelection();
        moveActiveCursor(-16);
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSDownArrowFunctionKey:
        clearByteSelection();
        moveActiveCursor(16);
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSHomeFunctionKey:
        clearByteSelection();
        writeBackCursor(hexedit::cursorToLineStart(currentCursor()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    case NSEndFunctionKey:
        clearByteSelection();
        writeBackCursor(hexedit::cursorToLineEnd(currentCursor(), currentDocumentView()));
        [self reloadDataPreservingScrollOrigin:scrollOrigin];
        return;
    default:
        break;
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
    restoreHexTableScrollOrigin(NSZeroPoint);
    restoreHexTableScrollOriginLater(NSZeroPoint);
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

static size_t currentHighlightRow()
{
    const size_t bpr = static_cast<size_t>(currentBytesPerRow());
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

static void captureScintillaSelection()
{
    clearByteSelection();
    if (!previewScintillaHandle) {
        return;
    }

    const intptr_t start = sci(previewScintillaHandle, SCI_GETSELECTIONSTART, 0, 0);
    const intptr_t end = sci(previewScintillaHandle, SCI_GETSELECTIONEND, 0, 0);
    if (start < 0 || end < 0 || start == end) {
        return;
    }

    const size_t lower = static_cast<size_t>(std::min(start, end));
    const size_t upper = static_cast<size_t>(std::max(start, end));
    selectedByteStart = std::min(lower, previewBytes.size());
    selectedByteEnd = std::min(upper, previewBytes.size());
    if (selectedByteEnd <= selectedByteStart) {
        clearByteSelection();
        return;
    }

    activeCursorField = HexCursorField::Hex;
    activeByteOffset = selectedByteEnd;
    activeHexNibble = 0;
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

static bool copyHexSelectionToPasteboard()
{
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

static bool deleteHexSelection()
{
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

static bool pasteBytesFromPasteboard()
{
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
        alert.informativeText = [NSString stringWithFormat:L(@"goto.message"),
            std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH), currentOffset,
            std::clamp(g_addressWidth, HEX_MIN_ADDRESS_WIDTH, HEX_MAX_ADDRESS_WIDTH), totalLength];
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
    clearByteSelection();

    const NSInteger row = static_cast<NSInteger>(offset / static_cast<size_t>(currentBytesPerRow()));
    if (row >= 0 && row < hexTableView.numberOfRows) {
        [hexTableView scrollRowToVisible:row];
    }
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
    if (!hasByteSelection() || selectedByteEnd <= selectedByteStart) {
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
    if (!hasByteSelection() || selectedByteEnd <= selectedByteStart) {
        showMessage(L(@"app.title"), L(@"patternReplace.requireSelection"));
        return;
    }

    @autoreleasepool {
        const std::size_t length = selectedByteEnd - selectedByteStart;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(@"patternReplace.title");
        alert.informativeText = [NSString stringWithFormat:L(@"patternReplace.message"), length];
        [alert addButtonWithTitle:L(@"patternReplace.button")];
        [alert addButtonWithTitle:L(@"button.cancel")];

        NSTextField *patternField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        patternField.placeholderString = L(@"patternReplace.placeholder");
        patternField.accessibilityIdentifier = @"hex-editor.patternreplace.pattern";
        alert.accessoryView = patternField;
        [alert.window setInitialFirstResponder:patternField];

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
        NSString *summary = (bytesWritten == 1)
            ? L(@"patternReplace.summarySingular")
            : [NSString stringWithFormat:L(@"patternReplace.summaryPlural"), bytesWritten];
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
    saveHexPrefs();
    applyHexViewMode();
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
        statusLabel.font = [NSFont systemFontOfSize:std::max<CGFloat>([hexTableFont() pointSize] - 1.0, 9.0)];

        NSView *rootView = statusLabel.superview;
        if (rootView) {
            const CGFloat tableWidth = tableContainerWidth(font);
            NSRect rootFrame = rootView.frame;
            rootFrame.size.width = tableWidth;
            rootView.frame = rootFrame;

            statusLabel.frame = NSMakeRect(8, HEX_TABLE_HEIGHT - 20, tableWidth - 16, 16);
            table.enclosingScrollView.frame = NSMakeRect(0, 0, tableWidth, HEX_TABLE_HEIGHT - HEX_STATUS_HEIGHT);
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
    label.frame = NSMakeRect(8, HEX_TABLE_HEIGHT - 20, tableWidth - 16, 16);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    label.font = [NSFont systemFontOfSize:11.0];
    label.textColor = [NSColor secondaryLabelColor];
    label.accessibilityIdentifier = kHexEditorStatusAccessibilityID;
    [rootView addSubview:label];

    NSScrollView *scrollView = [[HexTableScrollView alloc] initWithFrame:NSMakeRect(0, 0, tableWidth, HEX_TABLE_HEIGHT - HEX_STATUS_HEIGHT)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSNoBorder;

    NSTableView *table = [[HexTableView alloc] initWithFrame:scrollView.contentView.bounds];
    table.accessibilityIdentifier = kHexEditorTableAccessibilityID;
    table.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    table.usesAlternatingRowBackgroundColors = NO;
    table.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
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

    if (previewBytes.size() < previewTotalLength) {
        return [NSString stringWithFormat:L(@"status.showingTruncated"),
            previewBytes.size(), previewTotalLength];
    }

    return [NSString stringWithFormat:L(@"status.showing"), previewBytes.size()];
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
    resetHexTableScrollOrigin();
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
        clearByteSelection();
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
    showMessage(L(@"app.titleMac"), L(@"about.body"));
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

    strlcpy(funcItem[5]._itemName, [L(@"menu.plugin.help") UTF8String], NPP_MENU_ITEM_SIZE);
    funcItem[5]._pFunc = showAbout;
    funcItem[5]._init2Check = false;
    funcItem[5]._pShKey = nullptr;
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
