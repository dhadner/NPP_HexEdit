#ifndef NPP_HEXEDITOR_HEXCORE_H
#define NPP_HEXEDITOR_HEXCORE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace hexedit {

enum class CursorField {
    Hex,
    Ascii
};

enum class CellNotation {
    Hex,
    Binary
};

struct ViewMode {
    int bytesPerCell = 1;
    CellNotation notation = CellNotation::Hex;
    bool littleEndian = false;
    // When true, formatCell emits A–F as uppercase ('A'…'F'). When false
    // (the default — preserves the historical render), digits are
    // lowercase. Has no effect when notation is Binary (0/1 only).
    bool uppercase = false;
};

struct CursorState {
    std::size_t offset = 0;
    int nibble = 0;
    CursorField field = CursorField::Hex;
};

struct Selection {
    std::size_t start = 0;
    std::size_t end = 0;

    bool active() const { return end > start; }
};

struct DocumentView {
    const std::uint8_t *bytes = nullptr;
    std::size_t visibleByteCount = 0;
    std::size_t totalLength = 0;

    bool fullyLoaded() const { return visibleByteCount == totalLength; }
    std::size_t maxEditableOffset() const { return fullyLoaded() ? totalLength : visibleByteCount; }
};

struct ByteRange {
    std::size_t offset = 0;
    std::size_t byteCount = 0;
};

// A rectangular block of bytes inside a fixed-row-width hex view. The block spans
// `width` bytes across `height` consecutive rows starting at `originOffset`, where
// originOffset is the top-left byte (rowStart * bytesPerRow + colStart). Rectangular
// selections are always anchored to a row width — if the viewport's bytes-per-row
// changes after the rectangle is created, the selection must be cleared by the caller
// because the geometry no longer maps to the same bytes on screen.
struct RectSelection {
    std::size_t originOffset = 0;
    std::size_t width = 0;
    std::size_t height = 0;
    std::size_t bytesPerRow = 0;

    bool active() const { return width > 0 && height > 0 && bytesPerRow > 0; }
    std::size_t totalBytes() const { return width * height; }
};

// Build a rectangular selection from two corner byte offsets. Either order works
// (anchor can be top-left, top-right, bottom-left, or bottom-right). Both offsets
// are clamped to [0, totalLength] before computing the rectangle. Returns an inactive
// rectangle (width=0 or height=0) when bytesPerRow is 0 or both offsets land on the
// same byte.
RectSelection makeRectSelection(std::size_t anchorOffset,
                                std::size_t endOffset,
                                std::size_t bytesPerRow,
                                std::size_t totalLength);

// Decompose the rectangle into one ByteRange per row, clipped to totalLength so the
// last row may yield a shorter range when the rectangle extends past EOF. Returns an
// empty vector for an inactive rectangle.
std::vector<ByteRange> rectToRanges(const RectSelection &rect, std::size_t totalLength);

// Extract a rectangle's bytes into a contiguous (width × height) buffer. Bytes that
// fall past EOF are zero-filled so the returned buffer always has rect.totalBytes()
// elements — this keeps the clipboard payload's shape stable even for rectangles
// that overhang the end of the file. Returns false (and leaves out untouched) for
// an inactive rectangle.
bool extractRectBytes(const std::uint8_t *bytes,
                      std::size_t totalLength,
                      const RectSelection &rect,
                      std::vector<std::uint8_t> &out);

// Hex-text rendering of a rectangle: each row's bytes formatted as space-separated
// 2-digit uppercase hex pairs, rows joined by '\n'. Used for the public-text fallback
// on the pasteboard so external apps see something usable, and for the parse-text
// paste path (Q2.b) on incoming clipboards from external apps.
std::string formatRectClipboardHex(const std::uint8_t *bytes,
                                   const RectSelection &rect,
                                   std::size_t totalLength);

// Parse a `\n`-separated text clipboard back into a rectangular byte buffer. Each
// non-empty line is treated as one row; the parser accepts either hex byte tokens
// (e.g. "DE AD BE EF" or "DEADBEEF") or, if every line fails as hex, the raw bytes
// of each line (UTF-8 encoded). All rows must have the same width — mismatched rows
// fail the parse. On success, outBytes contains width*height bytes in row-major
// order; outWidth and outHeight describe the shape. Returns false (and leaves the
// out parameters untouched) on empty / shape-mismatched / unparseable input.
bool parseRectClipboardText(const std::string &text,
                            std::vector<std::uint8_t> &outBytes,
                            std::size_t &outWidth,
                            std::size_t &outHeight);

// Strip the address column and trailing ASCII representation from a single line
// of a hex dump, returning just the byte-data substring. Recognises patterns
// emitted by common debuggers and hex tools:
//   lldb   : "0x100000000: 48 65 6c 6c 6f 20 77 6f  Hello wo"
//   gdb    : "0x7fff5fbff8c0: 0x48  0x65  0x6c  0x6c"
//   xxd    : "00000000: 4865 6c6c 6f20 776f  Hello wo"
//   x64dbg : "00007FF6BC471000 | 48 65 6C 6C 6F  Hello"
//   IDA    : "0001:0000  48 65 6C 6C 6F 20 57 6F"
//   C esc  : "\x48\x65\x6c\x6c"
//   C arr  : "{ 0x48, 0x65, 0x6c, 0x6c }"
//
// The cleaning rules:
//   * If the line opens with what looks like an address (4+ hex digits, optionally
//     prefixed with "0x", possibly with a "0001:0000" segment+offset form) and is
//     followed by a separator (":", "|", ">", or 2+ whitespace chars), strip
//     everything up to and including the separator.
//   * If the line contains 2+ consecutive whitespace chars and any non-hex / non-
//     separator content follows them, strip from that gap to end of line — the
//     trailing ASCII column.
//   * Replace "\x" / "\X" with whitespace so C-string escapes split into tokens.
//   * Replace braces/parens/brackets with whitespace so C array literals tokenise.
//
// Lines without an address pattern (e.g. plain "DE AD BE EF") pass through with
// only the brace/escape transformations. Returns the cleaned line; never fails.
std::string stripHexDumpAddressAndAscii(const std::string &line);

// Wire-format constants for the custom-UTI pasteboard payload that carries a
// rectangular selection between the plugin and itself across copy/paste. The
// header is 20 bytes:
//   [0..3]   magic = "HXR1"
//   [4]      version (1)
//   [5]      kind (RectClipboardKind)
//   [6..7]   reserved (zero)
//   [8..11]  width  (little-endian uint32)
//   [12..15] height (little-endian uint32)
//   [16..19] dataLength (little-endian uint32)
//   [20..]   raw bytes (length = dataLength; 0 for kind=Addresses)
extern const char kRectPayloadMagic[4];
extern const std::uint8_t kRectPayloadVersion;
extern const std::size_t kRectPayloadHeaderSize;

enum class RectClipboardKind : std::uint8_t {
    Bytes = 0,
    Ascii = 1,
    // (kind=2 was Addresses, retired in v1.1.x — the address column is no
    // longer selectable so address-source clipboards no longer exist.)
};

struct RectPayload {
    RectClipboardKind kind = RectClipboardKind::Bytes;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t dataLength = 0;
    const std::uint8_t *data = nullptr;
};

// Serialise a rect payload into the wire format. Always succeeds (returned vector
// has size kRectPayloadHeaderSize + dataLength). When dataLength is 0, data may
// be null — used for kind=Addresses where the text payload carries the user-visible
// content and the structured payload is just the shape + kind tag.
std::vector<std::uint8_t> encodeRectPayload(RectClipboardKind kind,
                                            std::uint32_t width,
                                            std::uint32_t height,
                                            const std::uint8_t *data,
                                            std::uint32_t dataLength);

// Validate + parse a wire-format payload. Returns false on bad magic, version
// mismatch, kind out of range, dataLength larger than the actual buffer, or
// truncated header. On success, out.data points into the input buffer (no copy
// is made — caller must not free the input until done with out).
//
// This is the function fed attacker-controlled bytes via the system pasteboard,
// so all bounds checking happens here and only here. Any width/height/dataLength
// is structurally validated against the input length. Caller is responsible for
// the SEMANTIC check that dataLength == width * height before treating .data as
// row-major byte content.
bool decodeRectPayload(const std::uint8_t *bytes, std::size_t length, RectPayload &out);

struct ByteEditOperation {
    std::size_t offset = 0;
    std::size_t replacedByteCount = 0;
    std::vector<std::uint8_t> replacement;
    CursorState nextCursor;
};

int hexDigitValue(int codepoint);

bool isVisibleEditableOffset(const DocumentView &view, std::size_t offset);

CursorState clampCursor(CursorState cursor, const DocumentView &view);

// Mode-aware variant. In binary notation `cursor.nibble` is interpreted as a bit index
// (0..7, MSB-first), so the upper clamp depends on subsPerByte = 8 for binary, 2 for hex.
CursorState clampCursor(CursorState cursor, const DocumentView &view, const ViewMode &mode);

CursorState moveCursor(const CursorState &cursor, long delta, const DocumentView &view);

CursorState cursorToLineStart(const CursorState &cursor);

CursorState cursorToLineEnd(const CursorState &cursor, const DocumentView &view);

CursorState cursorToDocumentStart(const CursorState &cursor);

CursorState cursorToDocumentEnd(const CursorState &cursor, const DocumentView &view);

CursorState navigateLeft(const CursorState &cursor, const DocumentView &view);

CursorState navigateRight(const CursorState &cursor, const DocumentView &view);

// View-aware navigation. Walks the display in left-to-right reading order rather than
// storage order — relevant when bytesPerCell > 1 with littleEndian display, where the
// physical byte at offset 0 displays *after* byte 1 in its cell. In default 8-Bit hex
// big-endian the result is identical to the byte-order overloads.
CursorState navigateLeft(const CursorState &cursor, const DocumentView &view, const ViewMode &mode, int bytesPerRow);

CursorState navigateRight(const CursorState &cursor, const DocumentView &view, const ViewMode &mode, int bytesPerRow);

ByteRange selectedOrCurrentRange(const DocumentView &view, const CursorState &cursor, const Selection &selection);

bool planHexDigitEdit(const DocumentView &view,
                      const CursorState &cursor,
                      const Selection &selection,
                      int hexValue,
                      ByteEditOperation &out);

// Binary-notation single-bit edit. cursor.nibble is the bit index (0=MSB, 7=LSB) within
// the byte at cursor.offset; bitValue must be 0 or 1. Replaces just that bit (preserving
// the other 7) and advances the cursor: bit + 1 within the byte, rolling to the next byte
// (offset + 1, bit = 0) when the low bit is reached. Append-at-EOF is permitted just like
// planHexDigitEdit — the new byte starts with the requested bit set/clear.
bool planBitEdit(const DocumentView &view,
                 const CursorState &cursor,
                 const Selection &selection,
                 int bitValue,
                 ByteEditOperation &out);

bool planAsciiByteEdit(const DocumentView &view,
                       const CursorState &cursor,
                       const Selection &selection,
                       std::uint8_t byteValue,
                       ByteEditOperation &out);

bool planDeleteEdit(const DocumentView &view,
                    const CursorState &cursor,
                    const Selection &selection,
                    ByteEditOperation &out);

bool planPasteEdit(const DocumentView &view,
                   const CursorState &cursor,
                   const Selection &selection,
                   const std::uint8_t *bytes,
                   std::size_t byteCount,
                   ByteEditOperation &out);

std::string formatHexClipboardText(const std::uint8_t *bytes, std::size_t count);

bool parseHexClipboardText(const std::string &text, std::vector<std::uint8_t> &out);

bool isValidBytesPerCell(int bytesPerCell);

int digitsPerCell(const ViewMode &mode);

int cellsPerRow(int bytesPerRow, int bytesPerCell);

std::string formatCell(const std::uint8_t *cellBytes, std::size_t available, const ViewMode &mode);

struct DisplayPosition {
    std::size_t cellIndex = 0;
    int digitInCell = 0;
};

struct PhysicalPosition {
    std::size_t byteInRow = 0;
    int subInByte = 0;
};

DisplayPosition displayPositionForByte(std::size_t byteInRow, int subInByte, const ViewMode &mode);

PhysicalPosition physicalPositionForDisplay(std::size_t cellIndex, int digitInCell, const ViewMode &mode);

bool resolveGotoOffset(const std::string &text,
                        std::size_t currentOffset,
                        std::size_t totalLength,
                        std::size_t &outOffset);

enum class SearchDirection {
    Forward,
    Backward
};

enum class SearchPatternKind {
    Ascii,
    Hex
};

struct SearchPattern {
    std::vector<std::uint8_t> bytes;
    SearchPatternKind kind = SearchPatternKind::Ascii;
    bool matchCase = true;
};

// Parse a user search expression. Heuristic:
//   - If the trimmed text starts with "0x"/"0X", or is otherwise composed only of
//     hex digits + whitespace + comma/separator characters AND has at least one
//     non-decimal hex digit (a-f) OR uses recognised hex separators, parse as hex.
//   - Otherwise treat as raw ASCII bytes.
// Returns false if the text is empty or a hex pattern parse fails.
bool parseSearchPattern(const std::string &text, bool matchCase, SearchPattern &out);

// Forward / backward byte-pattern search. Returns true and writes *outOffset on hit.
// startOffset is the position to begin searching FROM (forward = at-or-after; backward
// = before). When wrap is true and no match is found in the primary range, the search
// continues from the opposite end up to startOffset (exclusive) — Windows wrap semantics.
// matchCase = false is honoured only for SearchPatternKind::Ascii.
bool findBytePattern(const std::uint8_t *haystack,
                     std::size_t haystackLength,
                     const SearchPattern &pattern,
                     std::size_t startOffset,
                     SearchDirection direction,
                     bool wrap,
                     std::size_t &outOffset);

// Byte-level compare for the Compare HEX feature. Returns a bool-per-offset mask of
// length max(lenA, lenB): mask[i] = true when the byte at offset i differs between the
// two buffers (or when one buffer is shorter, so byte i is "missing"). Returns an empty
// vector if both buffers are identical (i.e. lenA == lenB and all bytes match).
std::vector<bool> computeByteDiffs(const std::uint8_t *a, std::size_t lenA,
                                    const std::uint8_t *b, std::size_t lenB);

// =============================================================================
// SCI buffer-read abstraction (testable without Scintilla)
// =============================================================================
//
// readPreviewBuffer() consolidates the buffer-shape logic that used to live
// inline in HexEditor.mm's readCurrentBuffer():
//
//   1. Compute bytesToRead = min(scintillaLength, previewLimit).
//   2. Allocate bytesToRead + 1 (Scintilla writes a trailing NUL terminator
//      at lpstrText[bytesToRead] — skipping the +1 caused a heap-buffer-overflow
//      that ASan would have caught had we exercised this path under ASan).
//   3. Send SCI_GETTEXTRANGEFULL via the abstract reader.
//   4. Resize the result back to bytesToRead (drop the NUL slot).
//
// SciReader is the abstraction. The real implementation lives in HexEditor.mm
// and forwards to sci(editor, ...). A FakeScintilla implementation in the unit
// tests obeys the documented SCI_GETTEXTRANGEFULL contract — including writing
// the NUL exactly where Scintilla does — so any heap-overrun in the buffer-shape
// code is caught by ASan during the unit-test pass.
class SciReader {
public:
    virtual ~SciReader() = default;

    // Returns the document length in bytes (Scintilla's SCI_GETLENGTH).
    virtual std::size_t documentLength() const = 0;

    // Fills `dest` with bytes from [cpMin, cpMax). `dest` must have room for
    // (cpMax - cpMin + 1) bytes — the trailing slot receives a NUL terminator
    // per the SCI_GETTEXTRANGEFULL contract. Implementations MUST write that
    // NUL so tests catch buffers sized without it.
    virtual void readRange(std::size_t cpMin, std::size_t cpMax, char *dest) const = 0;
};

// Read up to `previewLimit` bytes from the start of the document via the
// reader. Sets *outTotalLength to the document's full size (independent of
// truncation). Returns the bytes; the returned vector's size is at most
// previewLimit.
std::vector<std::uint8_t> readPreviewBuffer(const SciReader &reader,
                                            std::size_t previewLimit,
                                            std::size_t *outTotalLength);

}

#endif  // NPP_HEXEDITOR_HEXCORE_H
