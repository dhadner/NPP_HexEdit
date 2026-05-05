#include "HexCore.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>

namespace hexedit {

int hexDigitValue(int codepoint)
{
    if (codepoint >= '0' && codepoint <= '9') {
        return codepoint - '0';
    }
    if (codepoint >= 'A' && codepoint <= 'F') {
        return codepoint - 'A' + 10;
    }
    if (codepoint >= 'a' && codepoint <= 'f') {
        return codepoint - 'a' + 10;
    }
    return -1;
}

bool isVisibleEditableOffset(const DocumentView &view, std::size_t offset)
{
    if (offset < view.visibleByteCount) {
        return true;
    }
    return offset == view.totalLength && view.fullyLoaded();
}

CursorState clampCursor(CursorState cursor, const DocumentView &view)
{
    cursor.offset = std::min(cursor.offset, view.maxEditableOffset());
    cursor.nibble = std::clamp(cursor.nibble, 0, 1);
    return cursor;
}

CursorState clampCursor(CursorState cursor, const DocumentView &view, const ViewMode &mode)
{
    cursor.offset = std::min(cursor.offset, view.maxEditableOffset());
    const int subsPerByte = (mode.notation == CellNotation::Binary) ? 8 : 2;
    cursor.nibble = std::clamp(cursor.nibble, 0, subsPerByte - 1);
    return cursor;
}

CursorState moveCursor(const CursorState &cursor, long delta, const DocumentView &view)
{
    CursorState next = cursor;
    if (delta < 0 && cursor.offset < static_cast<std::size_t>(-delta)) {
        next.offset = 0;
    } else {
        next.offset = static_cast<std::size_t>(static_cast<long>(cursor.offset) + delta);
    }
    next.nibble = 0;
    return clampCursor(next, view);
}

CursorState cursorToLineStart(const CursorState &cursor)
{
    CursorState next = cursor;
    next.offset -= next.offset % 16;
    next.nibble = 0;
    return next;
}

CursorState cursorToLineEnd(const CursorState &cursor, const DocumentView &view)
{
    CursorState next = cursor;
    const std::size_t rowStart = next.offset - (next.offset % 16);
    next.offset = std::min(rowStart + 15, view.totalLength);
    next.nibble = 0;
    return clampCursor(next, view);
}

CursorState cursorToDocumentStart(const CursorState &cursor)
{
    CursorState next = cursor;
    next.offset = 0;
    next.nibble = 0;
    return next;
}

CursorState cursorToDocumentEnd(const CursorState &cursor, const DocumentView &view)
{
    CursorState next = cursor;
    next.offset = view.maxEditableOffset();
    next.nibble = 0;
    return clampCursor(next, view);
}

CursorState navigateLeft(const CursorState &cursor, const DocumentView &view)
{
    if (cursor.field == CursorField::Hex && cursor.nibble > 0) {
        CursorState next = cursor;
        next.nibble = 0;
        return next;
    }
    return moveCursor(cursor, -1, view);
}

CursorState navigateRight(const CursorState &cursor, const DocumentView &view)
{
    if (cursor.field == CursorField::Hex && cursor.nibble == 0 && cursor.offset < view.totalLength) {
        CursorState next = cursor;
        next.nibble = 1;
        return next;
    }
    return moveCursor(cursor, 1, view);
}

CursorState navigateLeft(const CursorState &cursor, const DocumentView &view, const ViewMode &mode, int bytesPerRow)
{
    if (cursor.field != CursorField::Hex || bytesPerRow <= 0 || !isValidBytesPerCell(mode.bytesPerCell)) {
        return navigateLeft(cursor, view);
    }

    const std::size_t bpr = static_cast<std::size_t>(bytesPerRow);
    const std::size_t row = cursor.offset / bpr;
    const std::size_t byteInRow = cursor.offset - row * bpr;
    DisplayPosition dp = displayPositionForByte(byteInRow, cursor.nibble, mode);
    const int dpc = digitsPerCell(mode);
    long flatDigit = static_cast<long>(dp.cellIndex) * dpc + dp.digitInCell;

    if (flatDigit > 0) {
        --flatDigit;
    } else {
        // At first display digit of row: walk to last digit of previous row, if any.
        if (row == 0) {
            return cursor;
        }
        const long perRow = static_cast<long>(bpr / static_cast<std::size_t>(mode.bytesPerCell)) * dpc;
        flatDigit = perRow - 1;
        const std::size_t newCell = static_cast<std::size_t>(flatDigit / dpc);
        const int newDigit = static_cast<int>(flatDigit % dpc);
        const PhysicalPosition pp = physicalPositionForDisplay(newCell, newDigit, mode);
        CursorState next = cursor;
        next.offset = (row - 1) * bpr + pp.byteInRow;
        next.nibble = pp.subInByte;
        return clampCursor(next, view, mode);
    }

    const std::size_t newCell = static_cast<std::size_t>(flatDigit / dpc);
    const int newDigit = static_cast<int>(flatDigit % dpc);
    const PhysicalPosition pp = physicalPositionForDisplay(newCell, newDigit, mode);
    CursorState next = cursor;
    next.offset = row * bpr + pp.byteInRow;
    next.nibble = pp.subInByte;
    return clampCursor(next, view, mode);
}

CursorState navigateRight(const CursorState &cursor, const DocumentView &view, const ViewMode &mode, int bytesPerRow)
{
    if (cursor.field != CursorField::Hex || bytesPerRow <= 0 || !isValidBytesPerCell(mode.bytesPerCell)) {
        return navigateRight(cursor, view);
    }

    const std::size_t bpr = static_cast<std::size_t>(bytesPerRow);
    const std::size_t row = cursor.offset / bpr;
    const std::size_t byteInRow = cursor.offset - row * bpr;
    DisplayPosition dp = displayPositionForByte(byteInRow, cursor.nibble, mode);
    const int dpc = digitsPerCell(mode);
    const long perRow = static_cast<long>(bpr / static_cast<std::size_t>(mode.bytesPerCell)) * dpc;
    long flatDigit = static_cast<long>(dp.cellIndex) * dpc + dp.digitInCell;

    if (flatDigit < perRow - 1) {
        ++flatDigit;
        const std::size_t newCell = static_cast<std::size_t>(flatDigit / dpc);
        const int newDigit = static_cast<int>(flatDigit % dpc);
        const PhysicalPosition pp = physicalPositionForDisplay(newCell, newDigit, mode);
        CursorState next = cursor;
        next.offset = row * bpr + pp.byteInRow;
        next.nibble = pp.subInByte;
        return clampCursor(next, view, mode);
    }

    // At last digit of row: advance to first digit of next row (or append slot).
    CursorState next = cursor;
    next.offset = (row + 1) * bpr;
    next.nibble = 0;
    if (next.offset > view.maxEditableOffset()) {
        next.offset = view.maxEditableOffset();
    }
    return clampCursor(next, view, mode);
}

ByteRange selectedOrCurrentRange(const DocumentView &view, const CursorState &cursor, const Selection &selection)
{
    ByteRange range;
    if (selection.active()) {
        range.offset = selection.start;
        range.byteCount = selection.end - selection.start;
        return range;
    }

    range.offset = std::min(cursor.offset, view.visibleByteCount);
    range.byteCount = (range.offset < view.visibleByteCount) ? 1 : 0;
    return range;
}

bool planHexDigitEdit(const DocumentView &view,
                      const CursorState &cursor,
                      const Selection &selection,
                      int hexValue,
                      ByteEditOperation &out)
{
    if (hexValue < 0 || hexValue > 15) {
        return false;
    }

    CursorState working = cursor;
    if (selection.active()) {
        working.offset = selection.start;
        working.nibble = 0;
    }

    if (!isVisibleEditableOffset(view, working.offset)) {
        return false;
    }

    std::uint8_t baseByte = 0;
    std::size_t replacedByteCount = 0;
    if (working.offset < view.visibleByteCount && view.source != nullptr) {
        view.source->read(working.offset, &baseByte, 1);
        replacedByteCount = 1;
    }

    std::uint8_t newByte = 0;
    if (working.nibble == 0) {
        newByte = static_cast<std::uint8_t>((static_cast<unsigned>(hexValue) << 4) | (baseByte & 0x0fu));
    } else {
        newByte = static_cast<std::uint8_t>((baseByte & 0xf0u) | static_cast<unsigned>(hexValue));
    }

    out.offset = working.offset;
    out.replacedByteCount = replacedByteCount;
    out.replacement = { newByte };

    CursorState nextCursor = working;
    nextCursor.field = CursorField::Hex;
    if (working.nibble == 0) {
        nextCursor.nibble = 1;
    } else {
        ++nextCursor.offset;
        nextCursor.nibble = 0;
    }
    out.nextCursor = clampCursor(nextCursor, view);
    return true;
}

bool planBitEdit(const DocumentView &view,
                 const CursorState &cursor,
                 const Selection &selection,
                 int bitValue,
                 ByteEditOperation &out)
{
    if (bitValue != 0 && bitValue != 1) {
        return false;
    }

    CursorState working = cursor;
    if (selection.active()) {
        working.offset = selection.start;
        working.nibble = 0;  // bit index 0 = MSB
    }

    if (!isVisibleEditableOffset(view, working.offset)) {
        return false;
    }
    if (working.nibble < 0 || working.nibble > 7) {
        return false;
    }

    std::uint8_t baseByte = 0;
    std::size_t replacedByteCount = 0;
    if (working.offset < view.visibleByteCount && view.source != nullptr) {
        view.source->read(working.offset, &baseByte, 1);
        replacedByteCount = 1;
    }

    // bit 0 = MSB → shift count = 7. bit 7 = LSB → shift count = 0.
    const int shift = 7 - working.nibble;
    const std::uint8_t mask = static_cast<std::uint8_t>(1u << shift);
    std::uint8_t newByte = static_cast<std::uint8_t>(baseByte & ~mask);
    if (bitValue == 1) {
        newByte = static_cast<std::uint8_t>(newByte | mask);
    }

    out.offset = working.offset;
    out.replacedByteCount = replacedByteCount;
    out.replacement = { newByte };

    CursorState nextCursor = working;
    nextCursor.field = CursorField::Hex;
    if (working.nibble < 7) {
        nextCursor.nibble = working.nibble + 1;
    } else {
        ++nextCursor.offset;
        nextCursor.nibble = 0;
    }
    // Clamp under binary semantics so the new bit position stays in 0..7.
    ViewMode binaryMode;
    binaryMode.notation = CellNotation::Binary;
    out.nextCursor = clampCursor(nextCursor, view, binaryMode);
    return true;
}

bool planAsciiByteEdit(const DocumentView &view,
                       const CursorState &cursor,
                       const Selection &selection,
                       std::uint8_t byteValue,
                       ByteEditOperation &out)
{
    CursorState working = cursor;
    if (selection.active()) {
        working.offset = selection.start;
    }
    working.nibble = 0;

    if (!isVisibleEditableOffset(view, working.offset)) {
        return false;
    }

    const std::size_t replacedByteCount = working.offset < view.visibleByteCount ? 1 : 0;

    out.offset = working.offset;
    out.replacedByteCount = replacedByteCount;
    out.replacement = { byteValue };

    CursorState nextCursor = working;
    nextCursor.field = CursorField::Ascii;
    ++nextCursor.offset;
    nextCursor.nibble = 0;
    out.nextCursor = clampCursor(nextCursor, view);
    return true;
}

bool planDeleteEdit(const DocumentView &view,
                    const CursorState &cursor,
                    const Selection &selection,
                    ByteEditOperation &out)
{
    ByteRange range = selectedOrCurrentRange(view, cursor, selection);
    if (range.byteCount == 0) {
        return false;
    }

    out.offset = range.offset;
    out.replacedByteCount = range.byteCount;
    out.replacement.clear();

    CursorState next = cursor;
    next.offset = range.offset;
    next.nibble = 0;
    out.nextCursor = clampCursor(next, view);
    return true;
}

bool planPasteEdit(const DocumentView &view,
                   const CursorState &cursor,
                   const Selection &selection,
                   const std::uint8_t *bytes,
                   std::size_t byteCount,
                   ByteEditOperation &out)
{
    if (byteCount == 0 || bytes == nullptr) {
        return false;
    }

    std::size_t offset;
    std::size_t replacedByteCount;
    if (selection.active()) {
        offset = selection.start;
        replacedByteCount = selection.end - selection.start;
    } else {
        offset = std::min(cursor.offset, view.totalLength);
        replacedByteCount = 0;
    }

    out.offset = offset;
    out.replacedByteCount = replacedByteCount;
    out.replacement.assign(bytes, bytes + byteCount);

    CursorState next = cursor;
    next.offset = offset + byteCount;
    next.nibble = 0;
    // Clamp to the OLD view; the adapter must re-clamp post-apply with the new total.
    out.nextCursor = clampCursor(next, view);
    return true;
}

std::string formatHexClipboardText(const std::uint8_t *bytes, std::size_t count)
{
    if (bytes == nullptr || count == 0) {
        return std::string();
    }

    static const char digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(count * 3 - 1);
    for (std::size_t i = 0; i < count; ++i) {
        if (i > 0) {
            out.push_back(' ');
        }
        out.push_back(digits[(bytes[i] >> 4) & 0x0F]);
        out.push_back(digits[bytes[i] & 0x0F]);
    }
    return out;
}

// Strip the address column + trailing ASCII column from one line of a hex dump.
// See HexCore.h for the supported tool output formats. Pure transformation: returns
// the line with non-byte content removed; never reports failure.
std::string stripHexDumpAddressAndAscii(const std::string &line)
{
    std::string s = line;

    // Strip trailing carriage return so "DE AD\r" → "DE AD" (CRLF tolerance handled
    // here so the caller's per-line loop can split on '\n' alone).
    if (!s.empty() && s.back() == '\r') {
        s.pop_back();
    }

    // 1. Detect + strip leading address. The address pattern is:
    //      [whitespace]* ( "0x" | "0X" )? [hex digits]+
    //      ( ":" [hex digits]+ )?              <-- IDA segment:offset form
    //      [whitespace]* ( ":" | "|" | ">" )   <-- the separator we strip through
    //    OR
    //      [hex digits >= 4] followed by 2+ whitespace then more hex bytes (xxd-ish).
    //    A "hex digits" run of 1-2 chars by itself is a byte, NOT an address — the
    //    address heuristic requires either a clear separator or an unusually long
    //    hex run (4+ chars) followed by whitespace.
    {
        std::size_t i = 0;
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;

        const std::size_t addrStart = i;
        if (i + 1 < s.size() && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
            i += 2;
        }
        std::size_t hexRunStart = i;
        while (i < s.size() && hexDigitValue(static_cast<unsigned char>(s[i])) >= 0) ++i;
        const std::size_t hexRunLen = i - hexRunStart;

        bool stripped = false;
        if (hexRunLen > 0) {
            // IDA segment:offset form: "0001:0000  48 65 ..." — the first ':' after
            // the leading hex run is part of the address, not a separator. Skip it
            // and the following hex run.
            std::size_t scan = i;
            if (scan < s.size() && s[scan] == ':') {
                std::size_t after = scan + 1;
                std::size_t segHexStart = after;
                while (after < s.size() && hexDigitValue(static_cast<unsigned char>(s[after])) >= 0) ++after;
                if (after - segHexStart > 0) {
                    scan = after;
                }
            }
            // Skip whitespace after the address run(s).
            std::size_t wsStart = scan;
            while (scan < s.size() && std::isspace(static_cast<unsigned char>(s[scan]))) ++scan;
            const std::size_t wsLen = scan - wsStart;

            // Recognised separators after the address.
            if (scan < s.size() && (s[scan] == ':' || s[scan] == '|' || s[scan] == '>')) {
                ++scan;
                stripped = true;
            } else if (hexRunLen >= 4 && wsLen >= 1 && scan < s.size()) {
                // Address run was 4+ chars with whitespace afterwards — likely an
                // address even without an explicit separator. Only strip if what
                // follows looks like more hex bytes (so we don't over-eagerly
                // strip "DEADBEEF cafebabe" as "address: data").
                std::size_t peek = scan;
                std::size_t peekHexLen = 0;
                while (peek < s.size() && hexDigitValue(static_cast<unsigned char>(s[peek])) >= 0) {
                    ++peekHexLen;
                    ++peek;
                }
                if (peekHexLen >= 1 && peekHexLen <= 2) {
                    stripped = true;
                }
            }
            if (stripped) {
                s = s.substr(scan);
            } else {
                // Not an address line — restore the leading whitespace we walked past.
                (void)addrStart;
            }
        }
    }

    // 2. Strip trailing ASCII column. Walk past each 2+ whitespace gap and look
    //    at the FIRST token after the gap — if it's a valid 1-2 char hex byte
    //    (optionally "0x" / "\x" prefixed), keep scanning for the next gap; if
    //    it's anything else (longer hex run, contains non-hex chars, etc.),
    //    that's the ASCII column. The lldb format has an inner 2-space gap
    //    between bytes 7 and 8 followed by a real byte and a separate 2-space
    //    gap before the ASCII gloss, so a tail-as-a-whole heuristic mis-fires;
    //    per-gap-then-per-token is the right shape.
    auto isSeparator = [](char c) -> bool {
        return std::isspace(static_cast<unsigned char>(c)) ||
               c == ',' || c == ';' || c == ':' ||
               c == '-' || c == '_';
    };
    {
        std::size_t i = 0;
        while (i + 1 < s.size()) {
            if (!(std::isspace(static_cast<unsigned char>(s[i])) &&
                  std::isspace(static_cast<unsigned char>(s[i + 1])))) {
                ++i;
                continue;
            }
            // 2+ whitespace gap detected. Skip past it.
            std::size_t j = i + 2;
            while (j < s.size() && std::isspace(static_cast<unsigned char>(s[j]))) ++j;
            if (j >= s.size()) break;  // trailing whitespace only

            // Inspect the first token after the gap. Skip "0x" / "0X" prefix
            // (gdb-style per-byte) and "\x" / "\X" prefix (C-string escapes).
            std::size_t k = j;
            if (k + 1 < s.size() && s[k] == '0' && (s[k + 1] == 'x' || s[k + 1] == 'X')) {
                k += 2;
            } else if (k + 1 < s.size() && s[k] == '\\' && (s[k + 1] == 'x' || s[k + 1] == 'X')) {
                k += 2;
            }
            std::size_t hexLen = 0;
            while (k < s.size() && hexDigitValue(static_cast<unsigned char>(s[k])) >= 0) {
                ++hexLen;
                ++k;
            }
            const bool tokenEndsCleanly = (k == s.size() || isSeparator(s[k]));
            const bool isByteToken = hexLen >= 1 && hexLen <= 2 && tokenEndsCleanly;
            if (!isByteToken) {
                s.resize(i);
                break;
            }
            // Token IS a byte — keep scanning for the next gap, starting after the token.
            i = k;
        }
    }

    // 3. Replace "\x" / "\X" with whitespace so C-string escape sequences split into
    //    tokens. Also handle braces / parens / brackets the same way so C array
    //    literals like "{0x48, 0x65}" tokenise cleanly.
    {
        std::string out;
        out.reserve(s.size());
        for (std::size_t i = 0; i < s.size(); ++i) {
            const char c = s[i];
            if (c == '\\' && i + 1 < s.size() && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
                out.push_back(' ');
                ++i;  // skip 'x'/'X' (loop ++i skips the backslash position)
                continue;
            }
            if (c == '{' || c == '}' || c == '(' || c == ')' || c == '[' || c == ']') {
                out.push_back(' ');
                continue;
            }
            out.push_back(c);
        }
        s = std::move(out);
    }

    return s;
}

namespace {

// Apply stripHexDumpAddressAndAscii to every '\n'-delimited line in `text` and
// return the cleaned concatenation. Used by the linear + rectangular parsers to
// normalise tool output before the byte-tokenising loop runs.
std::string preprocessHexDumpText(const std::string &text)
{
    std::string out;
    out.reserve(text.size());
    std::size_t lineStart = 0;
    for (std::size_t i = 0; i <= text.size(); ++i) {
        if (i == text.size() || text[i] == '\n') {
            const std::string line = text.substr(lineStart, i - lineStart);
            out += stripHexDumpAddressAndAscii(line);
            if (i < text.size()) {
                out.push_back('\n');
            }
            lineStart = i + 1;
        }
    }
    return out;
}

}  // namespace

bool parseHexClipboardText(const std::string &text, std::vector<std::uint8_t> &out)
{
    out.clear();

    // Pre-process to strip address columns + ASCII columns + C-style escapes from
    // common debugger hex-dump formats (lldb, gdb, xxd, x64dbg, IDA, C arrays).
    // The cleaned text contains only byte tokens + whitespace + separators which
    // the loop below already handles. See stripHexDumpAddressAndAscii in the
    // header for the recognised format catalogue.
    const std::string cleaned = preprocessHexDumpText(text);

    int pendingDigit = -1;
    bool sawAnyDigit = false;
    std::size_t i = 0;
    while (i < cleaned.size()) {
        unsigned char c = static_cast<unsigned char>(cleaned[i]);

        if (std::isspace(c)) {
            if (pendingDigit >= 0) {
                out.push_back(static_cast<std::uint8_t>(pendingDigit));
                pendingDigit = -1;
            }
            ++i;
            continue;
        }

        if (c == '0' && i + 1 < cleaned.size() && (cleaned[i + 1] == 'x' || cleaned[i + 1] == 'X')) {
            i += 2;
            continue;
        }

        if (c == ',' || c == ';' || c == ':' || c == '-' || c == '_') {
            if (pendingDigit >= 0) {
                out.push_back(static_cast<std::uint8_t>(pendingDigit));
                pendingDigit = -1;
            }
            ++i;
            continue;
        }

        const int value = hexDigitValue(c);
        if (value < 0) {
            out.clear();
            return false;
        }

        sawAnyDigit = true;
        if (pendingDigit < 0) {
            pendingDigit = value << 4;
        } else {
            out.push_back(static_cast<std::uint8_t>(pendingDigit | value));
            pendingDigit = -1;
        }
        ++i;
    }

    if (pendingDigit >= 0) {
        out.clear();
        return false;
    }

    return sawAnyDigit;
}

bool isValidBytesPerCell(int bytesPerCell)
{
    return bytesPerCell == 1 || bytesPerCell == 2 || bytesPerCell == 4 || bytesPerCell == 8;
}

int digitsPerCell(const ViewMode &mode)
{
    if (!isValidBytesPerCell(mode.bytesPerCell)) {
        return 0;
    }
    return mode.notation == CellNotation::Binary ? mode.bytesPerCell * 8 : mode.bytesPerCell * 2;
}

int cellsPerRow(int bytesPerRow, int bytesPerCell)
{
    if (!isValidBytesPerCell(bytesPerCell) || bytesPerRow <= 0) {
        return 0;
    }
    return bytesPerRow / bytesPerCell;
}

DisplayPosition displayPositionForByte(std::size_t byteInRow, int subInByte, const ViewMode &mode)
{
    DisplayPosition out;
    if (!isValidBytesPerCell(mode.bytesPerCell)) {
        return out;
    }
    const int bpc = mode.bytesPerCell;
    out.cellIndex = byteInRow / static_cast<std::size_t>(bpc);
    const int byteInCell = static_cast<int>(byteInRow % static_cast<std::size_t>(bpc));
    const int displayedByteInCell = mode.littleEndian ? (bpc - 1 - byteInCell) : byteInCell;
    const int subsPerByte = (mode.notation == CellNotation::Binary) ? 8 : 2;
    int sub = subInByte;
    if (sub < 0) sub = 0;
    if (sub >= subsPerByte) sub = subsPerByte - 1;
    out.digitInCell = displayedByteInCell * subsPerByte + sub;
    return out;
}

namespace {

inline std::string trimGotoExpression(const std::string &text)
{
    std::size_t first = 0;
    while (first < text.size() && std::isspace(static_cast<unsigned char>(text[first]))) {
        ++first;
    }
    std::size_t last = text.size();
    while (last > first && std::isspace(static_cast<unsigned char>(text[last - 1]))) {
        --last;
    }
    return text.substr(first, last - first);
}

}  // namespace

bool resolveGotoOffset(const std::string &text,
                        std::size_t currentOffset,
                        std::size_t totalLength,
                        std::size_t &outOffset)
{
    const std::string trimmed = trimGotoExpression(text);
    if (trimmed.empty()) {
        return false;
    }

    enum class Mode { Absolute, RelativeForward, RelativeBackward };
    Mode mode = Mode::Absolute;
    std::size_t cursor = 0;

    if (trimmed[cursor] == '+') {
        mode = Mode::RelativeForward;
        ++cursor;
    } else if (trimmed[cursor] == '-') {
        mode = Mode::RelativeBackward;
        ++cursor;
    }

    int base = 10;
    if (cursor + 1 < trimmed.size() && trimmed[cursor] == '0' &&
        (trimmed[cursor + 1] == 'x' || trimmed[cursor + 1] == 'X')) {
        base = 16;
        cursor += 2;
    }

    if (cursor >= trimmed.size()) {
        return false;
    }

    unsigned long long value = 0;
    while (cursor < trimmed.size()) {
        unsigned char c = static_cast<unsigned char>(trimmed[cursor]);
        if (std::isspace(c) || c == '_' || c == ',') {
            ++cursor;
            continue;
        }
        const int digit = hexDigitValue(c);
        if (digit < 0 || digit >= base) {
            return false;
        }
        const unsigned long long next = value * static_cast<unsigned long long>(base) + static_cast<unsigned long long>(digit);
        if (next < value) {
            return false;
        }
        value = next;
        ++cursor;
    }

    std::size_t target = 0;
    switch (mode) {
        case Mode::Absolute:
            target = static_cast<std::size_t>(value);
            break;
        case Mode::RelativeForward: {
            const std::size_t delta = static_cast<std::size_t>(value);
            if (delta > totalLength - currentOffset) {
                target = totalLength;
            } else {
                target = currentOffset + delta;
            }
            break;
        }
        case Mode::RelativeBackward: {
            const std::size_t delta = static_cast<std::size_t>(value);
            target = (delta >= currentOffset) ? 0 : currentOffset - delta;
            break;
        }
    }

    if (target > totalLength) {
        target = totalLength;
    }

    outOffset = target;
    return true;
}

namespace {

inline std::uint8_t toLowerAscii(std::uint8_t value)
{
    return (value >= 'A' && value <= 'Z') ? static_cast<std::uint8_t>(value + ('a' - 'A')) : value;
}

bool bytesEqualAtCase(const std::uint8_t *haystack, const std::uint8_t *needle, std::size_t length, bool caseSensitive)
{
    if (caseSensitive) {
        return std::memcmp(haystack, needle, length) == 0;
    }
    for (std::size_t i = 0; i < length; ++i) {
        if (toLowerAscii(haystack[i]) != toLowerAscii(needle[i])) {
            return false;
        }
    }
    return true;
}

bool searchInRange(const std::uint8_t *haystack,
                   std::size_t rangeStart,
                   std::size_t rangeEnd,
                   const std::uint8_t *needle,
                   std::size_t needleLength,
                   bool matchCase,
                   bool isHex,
                   SearchDirection direction,
                   std::size_t &outOffset)
{
    if (needleLength == 0 || rangeEnd < rangeStart || rangeEnd - rangeStart < needleLength) {
        return false;
    }
    const bool caseSensitive = isHex || matchCase;
    if (direction == SearchDirection::Forward) {
        const std::size_t lastStart = rangeEnd - needleLength;
        for (std::size_t i = rangeStart; i <= lastStart; ++i) {
            if (bytesEqualAtCase(haystack + i, needle, needleLength, caseSensitive)) {
                outOffset = i;
                return true;
            }
        }
    } else {
        const std::size_t lastStart = rangeEnd - needleLength;
        std::size_t i = lastStart + 1;
        while (i > rangeStart) {
            --i;
            if (bytesEqualAtCase(haystack + i, needle, needleLength, caseSensitive)) {
                outOffset = i;
                return true;
            }
            if (i == rangeStart) {
                break;
            }
        }
    }
    return false;
}

}  // namespace

bool parseSearchPattern(const std::string &text, bool matchCase, SearchPattern &out)
{
    out.bytes.clear();
    out.kind = SearchPatternKind::Ascii;
    out.matchCase = matchCase;

    if (text.empty()) {
        return false;
    }

    // Hex auto-detection is intentionally conservative — a bare token like "CD" must
    // remain ASCII (chars 'C','D'), not be re-interpreted as hex byte 0xCD. Hex requires
    // either an explicit "0x"/"0X" prefix or a recognised separator (space, comma, etc.)
    // proving the user is grouping byte values. Without that, fall back to ASCII so
    // human-readable searches like "ELF" or "TODO" work as expected.
    bool explicitHex = false;
    if (text.size() >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        explicitHex = true;
    }

    bool hasSeparator = false;
    bool allHexCompatible = true;
    for (unsigned char c : text) {
        if (std::isspace(c) || c == ',' || c == ';' || c == ':' || c == '-' || c == '_') {
            hasSeparator = true;
            continue;
        }
        if (hexDigitValue(c) < 0) {
            allHexCompatible = false;
            break;
        }
    }

    if (explicitHex || (allHexCompatible && hasSeparator)) {
        std::vector<std::uint8_t> bytes;
        if (!parseHexClipboardText(text, bytes)) {
            return false;
        }
        out.bytes = std::move(bytes);
        out.kind = SearchPatternKind::Hex;
        return !out.bytes.empty();
    }

    // ASCII fallback: bytes are the raw chars.
    out.bytes.assign(text.begin(), text.end());
    out.kind = SearchPatternKind::Ascii;
    return true;
}

namespace {

// Search-engine chunk size for streaming finds against a ByteSource. 64 KB
// keeps plugin RAM bounded regardless of file size, while being large enough
// that per-chunk overhead (one virtual call + the needleLen-1 byte overlap)
// is negligible compared to the byte-by-byte search cost.
constexpr std::size_t kSearchChunkSize = 64 * 1024;

// Streaming variant of searchInRange that reads chunks from a ByteSource
// instead of a raw pointer. Each chunk covers [chunkStart, chunkStart +
// kSearchChunkSize + needleLen - 1) so a needle straddling a chunk boundary
// is found exactly once, in the chunk that begins before it.
bool searchInRangeStreamed(const ByteSource &source,
                           std::size_t rangeStart,
                           std::size_t rangeEnd,
                           const std::uint8_t *needle,
                           std::size_t needleLength,
                           bool matchCase,
                           bool isHex,
                           SearchDirection direction,
                           std::size_t &outOffset)
{
    if (needleLength == 0 || rangeEnd < rangeStart || rangeEnd - rangeStart < needleLength) {
        return false;
    }

    std::vector<std::uint8_t> buffer(kSearchChunkSize + needleLength - 1);

    if (direction == SearchDirection::Forward) {
        std::size_t pos = rangeStart;
        while (pos + needleLength <= rangeEnd) {
            const std::size_t want = std::min(buffer.size(), rangeEnd - pos);
            const std::size_t got = source.read(pos, buffer.data(), want);
            if (got < needleLength) {
                return false;
            }
            // Last position in this chunk where a needle could still start AND
            // still fit fully inside the chunk we just read.
            const std::size_t lastStartInChunk = got - needleLength;
            std::size_t hit = 0;
            if (searchInRange(buffer.data(), 0, lastStartInChunk + needleLength,
                              needle, needleLength, matchCase, isHex, direction, hit)) {
                outOffset = pos + hit;
                return true;
            }
            // Advance by kSearchChunkSize (NOT got) so the overlap region is
            // re-read at the start of the next chunk — that overlap exists so
            // matches straddling the kSearchChunkSize boundary are caught.
            if (got <= needleLength - 1) {
                return false;
            }
            pos += kSearchChunkSize;
        }
        return false;
    }

    // Backward: walk chunks in descending order. Each chunk covers
    // [chunkStart, chunkStart + kSearchChunkSize + needleLength - 1) and
    // we ratchet chunkStart down by kSearchChunkSize per iteration.
    if (rangeEnd < rangeStart + needleLength) {
        return false;
    }
    std::size_t chunkEnd = rangeEnd;
    while (chunkEnd >= rangeStart + needleLength) {
        const std::size_t chunkStart = (chunkEnd >= rangeStart + buffer.size())
            ? (chunkEnd - buffer.size())
            : rangeStart;
        const std::size_t want = chunkEnd - chunkStart;
        const std::size_t got = source.read(chunkStart, buffer.data(), want);
        if (got < needleLength) {
            return false;
        }
        std::size_t hit = 0;
        if (searchInRange(buffer.data(), 0, got, needle, needleLength,
                          matchCase, isHex, direction, hit)) {
            outOffset = chunkStart + hit;
            return true;
        }
        if (chunkStart == rangeStart) {
            return false;
        }
        chunkEnd = chunkStart + (needleLength - 1);
    }
    return false;
}

}  // namespace

bool findBytePattern(const ByteSource &haystack,
                     const SearchPattern &pattern,
                     std::size_t startOffset,
                     SearchDirection direction,
                     bool wrap,
                     std::size_t &outOffset)
{
    const std::size_t haystackLength = haystack.length();
    if (pattern.bytes.empty() || pattern.bytes.size() > haystackLength) {
        return false;
    }
    if (startOffset > haystackLength) {
        startOffset = haystackLength;
    }

    const bool isHex = pattern.kind == SearchPatternKind::Hex;
    const std::uint8_t *needle = pattern.bytes.data();
    const std::size_t needleLen = pattern.bytes.size();

    if (direction == SearchDirection::Forward) {
        if (searchInRangeStreamed(haystack, startOffset, haystackLength, needle, needleLen,
                                  pattern.matchCase, isHex, direction, outOffset)) {
            return true;
        }
        if (!wrap) {
            return false;
        }
        const std::size_t wrapEnd = std::min(startOffset + needleLen - 1, haystackLength);
        return searchInRangeStreamed(haystack, 0, wrapEnd, needle, needleLen,
                                     pattern.matchCase, isHex, direction, outOffset);
    }

    // Backward
    if (startOffset >= needleLen) {
        if (searchInRangeStreamed(haystack, 0, startOffset, needle, needleLen,
                                  pattern.matchCase, isHex, direction, outOffset)) {
            return true;
        }
    }
    if (!wrap) {
        return false;
    }
    const std::size_t wrapStart = (startOffset >= needleLen - 1) ? (startOffset - (needleLen - 1)) : 0;
    if (wrapStart >= haystackLength) {
        return false;
    }
    return searchInRangeStreamed(haystack, wrapStart, haystackLength, needle, needleLen,
                                 pattern.matchCase, isHex, direction, outOffset);
}

std::vector<bool> computeByteDiffs(const ByteSource &a, const ByteSource &b)
{
    const std::size_t lenA = a.length();
    const std::size_t lenB = b.length();
    std::vector<bool> mask;

    constexpr std::size_t kCompareChunkSize = 64 * 1024;
    std::vector<std::uint8_t> bufA(kCompareChunkSize);
    std::vector<std::uint8_t> bufB(kCompareChunkSize);

    const std::size_t maxLen = std::max(lenA, lenB);
    const std::size_t minLen = std::min(lenA, lenB);
    mask.assign(maxLen, false);
    bool anyDiff = false;

    // Lock-step chunked compare across the overlapping prefix.
    for (std::size_t pos = 0; pos < minLen; pos += kCompareChunkSize) {
        const std::size_t want = std::min(kCompareChunkSize, minLen - pos);
        const std::size_t gotA = a.read(pos, bufA.data(), want);
        const std::size_t gotB = b.read(pos, bufB.data(), want);
        const std::size_t cmp = std::min(gotA, gotB);
        for (std::size_t i = 0; i < cmp; ++i) {
            if (bufA[i] != bufB[i]) {
                mask[pos + i] = true;
                anyDiff = true;
            }
        }
        if (gotA < want || gotB < want) {
            // A short read indicates the source ran out earlier than its
            // declared length — bail rather than mark false-diffs we can't
            // verify.
            break;
        }
    }
    // Bytes only present in one source count as "differing" (matches Windows DoCompare).
    for (std::size_t i = minLen; i < maxLen; ++i) {
        mask[i] = true;
        anyDiff = true;
    }

    if (!anyDiff) {
        mask.clear();
    }
    return mask;
}

PhysicalPosition physicalPositionForDisplay(std::size_t cellIndex, int digitInCell, const ViewMode &mode)
{
    PhysicalPosition out;
    if (!isValidBytesPerCell(mode.bytesPerCell)) {
        return out;
    }
    const int bpc = mode.bytesPerCell;
    const int subsPerByte = (mode.notation == CellNotation::Binary) ? 8 : 2;
    int digit = digitInCell;
    if (digit < 0) digit = 0;
    const int totalDigits = bpc * subsPerByte;
    if (digit >= totalDigits) digit = totalDigits - 1;

    const int displayedByteInCell = digit / subsPerByte;
    const int physicalByteInCell = mode.littleEndian ? (bpc - 1 - displayedByteInCell) : displayedByteInCell;
    out.byteInRow = cellIndex * static_cast<std::size_t>(bpc) + static_cast<std::size_t>(physicalByteInCell);
    out.subInByte = digit % subsPerByte;
    return out;
}

std::string formatCell(const std::uint8_t *cellBytes, std::size_t available, const ViewMode &mode)
{
    if (!isValidBytesPerCell(mode.bytesPerCell)) {
        return std::string();
    }

    static const char hexDigitsLower[] = "0123456789abcdef";
    static const char hexDigitsUpper[] = "0123456789ABCDEF";
    const char *hexDigits = mode.uppercase ? hexDigitsUpper : hexDigitsLower;
    const int bpc = mode.bytesPerCell;
    const int totalDigits = digitsPerCell(mode);

    std::string out;
    out.reserve(static_cast<std::size_t>(totalDigits));

    for (int displayedByte = 0; displayedByte < bpc; ++displayedByte) {
        const int physicalByteInCell = mode.littleEndian ? (bpc - 1 - displayedByte) : displayedByte;
        const bool havePhysical = (cellBytes != nullptr) && (static_cast<std::size_t>(physicalByteInCell) < available);
        const std::uint8_t value = havePhysical ? cellBytes[physicalByteInCell] : static_cast<std::uint8_t>(0);

        if (mode.notation == CellNotation::Binary) {
            for (int bit = 7; bit >= 0; --bit) {
                if (havePhysical) {
                    out.push_back(((value >> bit) & 0x01) ? '1' : '0');
                } else {
                    out.push_back(' ');
                }
            }
        } else {
            if (havePhysical) {
                out.push_back(hexDigits[(value >> 4) & 0x0F]);
                out.push_back(hexDigits[value & 0x0F]);
            } else {
                out.push_back(' ');
                out.push_back(' ');
            }
        }
    }

    return out;
}

RectSelection makeRectSelection(std::size_t anchorOffset,
                                std::size_t endOffset,
                                std::size_t bytesPerRow,
                                std::size_t totalLength)
{
    RectSelection rect;
    if (bytesPerRow == 0) {
        return rect;
    }

    if (anchorOffset > totalLength) anchorOffset = totalLength;
    if (endOffset > totalLength) endOffset = totalLength;

    const std::size_t anchorRow = anchorOffset / bytesPerRow;
    const std::size_t anchorCol = anchorOffset % bytesPerRow;
    const std::size_t endRow = endOffset / bytesPerRow;
    const std::size_t endCol = endOffset % bytesPerRow;

    const std::size_t rowStart = std::min(anchorRow, endRow);
    const std::size_t rowEnd = std::max(anchorRow, endRow);
    const std::size_t colStart = std::min(anchorCol, endCol);
    const std::size_t colEnd = std::max(anchorCol, endCol);

    rect.bytesPerRow = bytesPerRow;
    rect.originOffset = rowStart * bytesPerRow + colStart;
    rect.width = (colEnd - colStart) + 1;
    rect.height = (rowEnd - rowStart) + 1;
    return rect;
}

std::vector<ByteRange> rectToRanges(const RectSelection &rect, std::size_t totalLength)
{
    std::vector<ByteRange> ranges;
    if (!rect.active()) {
        return ranges;
    }
    // Bound the reserve by what we can actually iterate — the loop below
    // breaks once rowStartOffset exceeds totalLength, so we never push more
    // than (totalLength / bytesPerRow + 1) entries regardless of rect.height.
    // Without this cap, a huge attacker-influenced rect.height triggers an
    // allocation-size-too-big abort in vector::reserve (caught by ASan in
    // fuzz_makeRectSelection). The non-attack path is unaffected — under
    // PREVIEW_LIMIT (1 MB) and HEX_DEFAULT_COLUMNS (16), maxRows is at most
    // 65 537, well within rect.height's natural range.
    const std::size_t bpr = std::max(rect.bytesPerRow, static_cast<std::size_t>(1));
    const std::size_t maxRows = (totalLength / bpr) + 1;
    ranges.reserve(std::min(rect.height, maxRows));
    for (std::size_t r = 0; r < rect.height; ++r) {
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        if (rowStartOffset >= totalLength) {
            break;
        }
        const std::size_t available = totalLength - rowStartOffset;
        const std::size_t take = std::min(rect.width, available);
        ranges.push_back(ByteRange{rowStartOffset, take});
    }
    return ranges;
}

bool extractRectBytes(const ByteSource &source,
                      const RectSelection &rect,
                      std::vector<std::uint8_t> &out)
{
    if (!rect.active()) {
        return false;
    }
    // Defend against width × height overflowing size_t. In normal plugin use
    // the rect comes from makeRectSelection on a bounded selection so this
    // can't happen, but a malformed custom-UTI payload that survives upstream
    // checks could otherwise allocate gigabytes. Reject up front.
    if (rect.width != 0 && rect.height > std::numeric_limits<std::size_t>::max() / rect.width) {
        return false;
    }
    out.assign(rect.totalBytes(), 0);
    const std::size_t totalLength = source.length();
    for (std::size_t r = 0; r < rect.height; ++r) {
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        if (rowStartOffset >= totalLength) {
            // Remaining rows are entirely past EOF; out's tail is already zero-filled.
            break;
        }
        const std::size_t available = totalLength - rowStartOffset;
        const std::size_t take = std::min(rect.width, available);
        // ByteSource::read fills exactly `got` bytes (not necessarily all of `take`)
        // so we leave any unfilled tail zero (out was zero-initialised).
        source.read(rowStartOffset, &out[r * rect.width], take);
    }
    return true;
}

static const char kHexUpper[16] = {
    '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'
};

std::string formatRectClipboardHex(const ByteSource &source,
                                   const RectSelection &rect)
{
    std::string out;
    if (!rect.active()) {
        return out;
    }
    // Each row: width * 2 hex chars + (width - 1) spaces. Plus '\n' between rows.
    out.reserve(rect.height * (rect.width * 3 + 1));
    // Read each row in one go into a small scratch buffer rather than calling
    // source.read() per byte — for a typical 16-byte rect that's one virtual
    // call per row instead of 16, and for a wide rect (e.g. 64-byte cells) it
    // matters more.
    std::vector<std::uint8_t> rowBuf(rect.width);
    for (std::size_t r = 0; r < rect.height; ++r) {
        if (r > 0) {
            out.push_back('\n');
        }
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        std::fill(rowBuf.begin(), rowBuf.end(), static_cast<std::uint8_t>(0));
        source.read(rowStartOffset, rowBuf.data(), rect.width);
        for (std::size_t c = 0; c < rect.width; ++c) {
            if (c > 0) {
                out.push_back(' ');
            }
            const std::uint8_t value = rowBuf[c];
            out.push_back(kHexUpper[(value >> 4) & 0x0F]);
            out.push_back(kHexUpper[value & 0x0F]);
        }
    }
    return out;
}

namespace {

// Tokenise a single line into hex bytes. Accepts space / comma / colon / semicolon
// separators, and tolerates an optional "0x" or "0X" prefix on each token. Returns
// false on any non-hex input. An empty line yields an empty result and returns true
// — the caller decides whether empty rows are allowed.
bool tryParseHexLine(const std::string &line, std::vector<std::uint8_t> &out)
{
    out.clear();
    std::string current;
    auto flushPair = [&](const std::string &tok) -> bool {
        if (tok.empty()) return true;
        // Each token must be 1 or 2 hex digits. Two digits = one byte; one digit =
        // 0x0X (matches the find-pattern parser's tolerance).
        if (tok.size() != 1 && tok.size() != 2) {
            return false;
        }
        std::uint8_t value = 0;
        for (char c : tok) {
            const int digit = hexDigitValue(static_cast<unsigned char>(c));
            if (digit < 0) return false;
            value = static_cast<std::uint8_t>((value << 4) | digit);
        }
        out.push_back(value);
        return true;
    };
    auto isSep = [](char c) -> bool {
        return c == ' ' || c == '\t' || c == ',' || c == ';' || c == ':';
    };
    for (std::size_t i = 0; i < line.size(); ++i) {
        const char c = line[i];
        if (isSep(c)) {
            if (!flushPair(current)) return false;
            current.clear();
            continue;
        }
        // Skip "0x" / "0X" prefix at the start of a token.
        if (current.empty() && c == '0' && i + 1 < line.size() &&
            (line[i + 1] == 'x' || line[i + 1] == 'X')) {
            ++i;
            continue;
        }
        current.push_back(c);
        // If we already have 2 chars and the next char is a hex digit, flush so
        // that "DEADBEEF" (no separators) splits into DE AD BE EF.
        if (current.size() == 2) {
            if (!flushPair(current)) return false;
            current.clear();
        }
    }
    return flushPair(current);
}

}  // namespace

bool parseRectClipboardText(const std::string &text,
                            std::vector<std::uint8_t> &outBytes,
                            std::size_t &outWidth,
                            std::size_t &outHeight)
{
    if (text.empty()) {
        return false;
    }
    // Split on '\n', trimming trailing '\r' (so CRLF clipboards work).
    std::vector<std::string> lines;
    {
        std::string current;
        for (char c : text) {
            if (c == '\n') {
                if (!current.empty() && current.back() == '\r') current.pop_back();
                lines.push_back(std::move(current));
                current.clear();
            } else {
                current.push_back(c);
            }
        }
        if (!current.empty() && current.back() == '\r') current.pop_back();
        if (!current.empty() || lines.empty()) {
            lines.push_back(std::move(current));
        }
    }
    // Trim trailing empty lines (a final "\n" leaves an empty tail).
    while (lines.size() > 1 && lines.back().empty()) {
        lines.pop_back();
    }
    if (lines.empty() || (lines.size() == 1 && lines.front().empty())) {
        return false;
    }

    // First pass: try to parse every line as hex. Each line is preprocessed
    // through stripHexDumpAddressAndAscii first so debugger / xxd / x64dbg
    // dumps with leading addresses + trailing ASCII columns parse cleanly
    // into the bytes-only middle. If any line fails the hex parse, fall back
    // to raw-bytes mode (each ORIGINAL line treated as its own byte sequence
    // — the user pasted plain ASCII, e.g. "abcd\nefgh", probably intending
    // an ASCII rectangle).
    std::vector<std::vector<std::uint8_t>> rows;
    rows.reserve(lines.size());
    bool allHex = true;
    for (const auto &line : lines) {
        std::vector<std::uint8_t> rowBytes;
        const std::string cleaned = stripHexDumpAddressAndAscii(line);
        if (!tryParseHexLine(cleaned, rowBytes)) {
            allHex = false;
            break;
        }
        rows.push_back(std::move(rowBytes));
    }
    if (!allHex) {
        rows.clear();
        for (const auto &line : lines) {
            rows.emplace_back(line.begin(), line.end());
        }
    }

    // All rows must have the same width.
    const std::size_t width = rows.front().size();
    if (width == 0) {
        return false;
    }
    for (const auto &row : rows) {
        if (row.size() != width) {
            return false;
        }
    }

    outBytes.clear();
    outBytes.reserve(width * rows.size());
    for (const auto &row : rows) {
        outBytes.insert(outBytes.end(), row.begin(), row.end());
    }
    outWidth = width;
    outHeight = rows.size();
    return true;
}

const char kRectPayloadMagic[4] = {'H', 'X', 'R', '1'};
const std::uint8_t kRectPayloadVersion = 1;
const std::size_t kRectPayloadHeaderSize = 20;

std::vector<std::uint8_t> encodeRectPayload(RectClipboardKind kind,
                                            std::uint32_t width,
                                            std::uint32_t height,
                                            const std::uint8_t *data,
                                            std::uint32_t dataLength)
{
    std::vector<std::uint8_t> payload;
    payload.reserve(kRectPayloadHeaderSize + dataLength);
    payload.insert(payload.end(), std::begin(kRectPayloadMagic), std::end(kRectPayloadMagic));
    payload.push_back(kRectPayloadVersion);
    payload.push_back(static_cast<std::uint8_t>(kind));
    payload.push_back(0);
    payload.push_back(0);
    auto appendLE32 = [&](std::uint32_t value) {
        payload.push_back(static_cast<std::uint8_t>(value & 0xFF));
        payload.push_back(static_cast<std::uint8_t>((value >> 8) & 0xFF));
        payload.push_back(static_cast<std::uint8_t>((value >> 16) & 0xFF));
        payload.push_back(static_cast<std::uint8_t>((value >> 24) & 0xFF));
    };
    appendLE32(width);
    appendLE32(height);
    appendLE32(dataLength);
    if (data != nullptr && dataLength > 0) {
        payload.insert(payload.end(), data, data + dataLength);
    }
    return payload;
}

bool decodeRectPayload(const std::uint8_t *bytes, std::size_t length, RectPayload &out)
{
    if (bytes == nullptr || length < kRectPayloadHeaderSize) {
        return false;
    }
    if (std::memcmp(bytes, kRectPayloadMagic, sizeof(kRectPayloadMagic)) != 0) {
        return false;
    }
    if (bytes[4] != kRectPayloadVersion) {
        return false;
    }
    const std::uint8_t kindByte = bytes[5];
    if (kindByte > static_cast<std::uint8_t>(RectClipboardKind::Ascii)) {
        return false;
    }
    auto readLE32 = [bytes](std::size_t offset) -> std::uint32_t {
        return static_cast<std::uint32_t>(bytes[offset]) |
               (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
               (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
               (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
    };
    const std::uint32_t width = readLE32(8);
    const std::uint32_t height = readLE32(12);
    const std::uint32_t dataLength = readLE32(16);
    // Bounds check against the actual input — the attacker-controlled dataLength
    // header field cannot promise more bytes than the pasteboard handed us.
    // size_t arithmetic is overflow-safe here because length is bounded by the
    // pasteboard's allocator (NSData can't realistically exceed SIZE_MAX/2 on a
    // user's Mac), and kRectPayloadHeaderSize is 20.
    if (dataLength > length - kRectPayloadHeaderSize) {
        return false;
    }
    out.kind = static_cast<RectClipboardKind>(kindByte);
    out.width = width;
    out.height = height;
    out.dataLength = dataLength;
    out.data = (dataLength > 0) ? (bytes + kRectPayloadHeaderSize) : nullptr;
    return true;
}

// =============================================================================
// readPreviewBuffer — SCI buffer-read abstraction
// =============================================================================

std::vector<std::uint8_t> readPreviewBuffer(const SciReader &reader,
                                            std::size_t previewLimit,
                                            std::size_t *outTotalLength)
{
    const std::size_t total = reader.documentLength();
    if (outTotalLength != nullptr) {
        *outTotalLength = total;
    }
    if (total == 0) {
        return {};
    }
    const std::size_t bytesToRead = (total < previewLimit) ? total : previewLimit;

    // Scintilla's SCI_GETTEXTRANGEFULL writes a trailing NUL at
    // lpstrText[cpMax - cpMin], so the destination buffer must have room for
    // bytesToRead + 1. Allocating exactly bytesToRead corrupts the heap by
    // one byte and was the bug that motivated this entire abstraction —
    // verified end-to-end: HexCoreTests's testReadPreviewBuffer (under ASan)
    // aborts on the NUL write if you remove the `+ 1` here.
    std::vector<std::uint8_t> bytes(bytesToRead + 1);
    reader.readRange(0, bytesToRead, reinterpret_cast<char *>(bytes.data()));
    bytes.resize(bytesToRead);   // drop the NUL slot from the returned size
    return bytes;
}

// =============================================================================
// WindowedScintillaByteSource — page-cached random-access read of a Scintilla
// document.
// =============================================================================

WindowedScintillaByteSource::WindowedScintillaByteSource(SciReader &reader,
                                                          std::size_t pageSize,
                                                          std::size_t maxPages)
    : reader_(reader),
      pageSize_(pageSize == 0 ? 64 * 1024 : pageSize),
      maxPages_(maxPages == 0 ? 1 : maxPages),
      lruCounter_(0)
{
    pages_.reserve(maxPages_);
}

std::size_t WindowedScintillaByteSource::length() const
{
    return reader_.documentLength();
}

void WindowedScintillaByteSource::invalidate()
{
    pages_.clear();
    lruCounter_ = 0;
}

const WindowedScintillaByteSource::Page &
WindowedScintillaByteSource::loadPage(std::size_t pageIndex) const
{
    // Cache hit: bump LRU and return.
    for (auto &p : pages_) {
        if (p.pageIndex == pageIndex) {
            p.lru = ++lruCounter_;
            return p;
        }
    }
    // Cache miss: fetch the page from Scintilla.
    const std::size_t docLen = reader_.documentLength();
    const std::size_t cpMin = pageIndex * pageSize_;
    const std::size_t cpMax = (cpMin >= docLen) ? cpMin : std::min(cpMin + pageSize_, docLen);
    const std::size_t bytesInPage = cpMax - cpMin;

    Page newPage;
    newPage.pageIndex = pageIndex;
    // SciReader::readRange writes a NUL at dest[cpMax - cpMin]; the buffer
    // must have room for bytesInPage + 1 bytes. Same bug-class as
    // readPreviewBuffer above.
    if (bytesInPage > 0) {
        newPage.bytes.resize(bytesInPage + 1);
        reader_.readRange(cpMin, cpMax, reinterpret_cast<char *>(newPage.bytes.data()));
        newPage.bytes.resize(bytesInPage);
    }
    newPage.lru = ++lruCounter_;

    // Evict the LRU page when at capacity.
    if (pages_.size() >= maxPages_) {
        auto victim = std::min_element(pages_.begin(), pages_.end(),
            [](const Page &a, const Page &b) { return a.lru < b.lru; });
        pages_.erase(victim);
    }
    pages_.push_back(std::move(newPage));
    return pages_.back();
}

std::size_t WindowedScintillaByteSource::read(std::size_t offset,
                                              std::uint8_t *dest,
                                              std::size_t count) const
{
    if (count == 0) return 0;
    const std::size_t docLen = reader_.documentLength();
    if (offset >= docLen) return 0;
    const std::size_t available = std::min(count, docLen - offset);

    std::size_t written = 0;
    while (written < available) {
        const std::size_t cursor = offset + written;
        const std::size_t pageIndex = cursor / pageSize_;
        const std::size_t pageOffset = cursor % pageSize_;
        const Page &page = loadPage(pageIndex);
        if (pageOffset >= page.bytes.size()) {
            // Page is shorter than expected (last page truncated); we've read
            // all available bytes.
            break;
        }
        const std::size_t take = std::min(available - written, page.bytes.size() - pageOffset);
        std::memcpy(dest + written, page.bytes.data() + pageOffset, take);
        written += take;
    }
    return written;
}

}
