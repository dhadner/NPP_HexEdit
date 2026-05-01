#include "HexCore.h"

#include <algorithm>
#include <cctype>
#include <cstring>

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
    if (working.offset < view.visibleByteCount) {
        baseByte = view.bytes[working.offset];
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
    if (working.offset < view.visibleByteCount) {
        baseByte = view.bytes[working.offset];
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

bool parseHexClipboardText(const std::string &text, std::vector<std::uint8_t> &out)
{
    out.clear();

    int pendingDigit = -1;
    bool sawAnyDigit = false;
    std::size_t i = 0;
    while (i < text.size()) {
        unsigned char c = static_cast<unsigned char>(text[i]);

        if (std::isspace(c)) {
            if (pendingDigit >= 0) {
                out.push_back(static_cast<std::uint8_t>(pendingDigit));
                pendingDigit = -1;
            }
            ++i;
            continue;
        }

        if (c == '0' && i + 1 < text.size() && (text[i + 1] == 'x' || text[i + 1] == 'X')) {
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

bool findBytePattern(const std::uint8_t *haystack,
                     std::size_t haystackLength,
                     const SearchPattern &pattern,
                     std::size_t startOffset,
                     SearchDirection direction,
                     bool wrap,
                     std::size_t &outOffset)
{
    if (haystack == nullptr || pattern.bytes.empty() || pattern.bytes.size() > haystackLength) {
        return false;
    }
    if (startOffset > haystackLength) {
        startOffset = haystackLength;
    }

    const bool isHex = pattern.kind == SearchPatternKind::Hex;
    const std::uint8_t *needle = pattern.bytes.data();
    const std::size_t needleLen = pattern.bytes.size();

    if (direction == SearchDirection::Forward) {
        // Primary range: [startOffset, haystackLength)
        if (searchInRange(haystack, startOffset, haystackLength, needle, needleLen,
                          pattern.matchCase, isHex, direction, outOffset)) {
            return true;
        }
        if (!wrap) {
            return false;
        }
        // Wrap range: [0, min(startOffset + needleLen - 1, haystackLength))
        const std::size_t wrapEnd = std::min(startOffset + needleLen - 1, haystackLength);
        return searchInRange(haystack, 0, wrapEnd, needle, needleLen,
                             pattern.matchCase, isHex, direction, outOffset);
    }

    // Backward
    // Primary range: [0, startOffset)
    if (startOffset >= needleLen) {
        if (searchInRange(haystack, 0, startOffset, needle, needleLen,
                          pattern.matchCase, isHex, direction, outOffset)) {
            return true;
        }
    }
    if (!wrap) {
        return false;
    }
    // Wrap range: [max(startOffset, 1) - 0, haystackLength). Approximation: search whole tail.
    const std::size_t wrapStart = (startOffset >= needleLen - 1) ? (startOffset - (needleLen - 1)) : 0;
    if (wrapStart >= haystackLength) {
        return false;
    }
    return searchInRange(haystack, wrapStart, haystackLength, needle, needleLen,
                         pattern.matchCase, isHex, direction, outOffset);
}

std::vector<bool> computeByteDiffs(const std::uint8_t *a, std::size_t lenA,
                                    const std::uint8_t *b, std::size_t lenB)
{
    std::vector<bool> mask;
    if (lenA == lenB && (a == nullptr || b == nullptr || std::memcmp(a, b, lenA) == 0)) {
        return mask;  // empty = identical
    }

    const std::size_t maxLen = std::max(lenA, lenB);
    mask.assign(maxLen, false);
    bool anyDiff = false;

    const std::size_t minLen = std::min(lenA, lenB);
    if (a != nullptr && b != nullptr) {
        for (std::size_t i = 0; i < minLen; ++i) {
            if (a[i] != b[i]) {
                mask[i] = true;
                anyDiff = true;
            }
        }
    }
    // Bytes only present in one buffer count as "differing" (matches Windows DoCompare).
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

    static const char hexDigits[] = "0123456789abcdef";
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
    ranges.reserve(rect.height);
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

bool extractRectBytes(const std::uint8_t *bytes,
                      std::size_t totalLength,
                      const RectSelection &rect,
                      std::vector<std::uint8_t> &out)
{
    if (!rect.active()) {
        return false;
    }
    out.assign(rect.totalBytes(), 0);
    if (bytes == nullptr) {
        // No source data — out is already zero-filled, which is the right answer
        // for an empty file plus an active rectangle (degenerate but valid).
        return true;
    }
    for (std::size_t r = 0; r < rect.height; ++r) {
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        if (rowStartOffset >= totalLength) {
            // Remaining rows are entirely past EOF; out's tail is already zero-filled.
            break;
        }
        const std::size_t available = totalLength - rowStartOffset;
        const std::size_t take = std::min(rect.width, available);
        std::memcpy(&out[r * rect.width], bytes + rowStartOffset, take);
        // Bytes [take .. rect.width) of this row are past EOF and stay zero.
    }
    return true;
}

static const char kHexUpper[16] = {
    '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'
};

std::string formatRectClipboardHex(const std::uint8_t *bytes,
                                   const RectSelection &rect,
                                   std::size_t totalLength)
{
    std::string out;
    if (!rect.active()) {
        return out;
    }
    // Each row: width * 2 hex chars + (width - 1) spaces. Plus '\n' between rows.
    out.reserve(rect.height * (rect.width * 3 + 1));
    for (std::size_t r = 0; r < rect.height; ++r) {
        if (r > 0) {
            out.push_back('\n');
        }
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        for (std::size_t c = 0; c < rect.width; ++c) {
            if (c > 0) {
                out.push_back(' ');
            }
            const std::size_t srcOffset = rowStartOffset + c;
            const std::uint8_t value = (bytes != nullptr && srcOffset < totalLength)
                ? bytes[srcOffset]
                : static_cast<std::uint8_t>(0);
            out.push_back(kHexUpper[(value >> 4) & 0x0F]);
            out.push_back(kHexUpper[value & 0x0F]);
        }
    }
    return out;
}

std::string formatRectClipboardAscii(const std::uint8_t *bytes,
                                     const RectSelection &rect,
                                     std::size_t totalLength)
{
    std::string out;
    if (!rect.active()) {
        return out;
    }
    out.reserve(rect.height * (rect.width + 1));
    for (std::size_t r = 0; r < rect.height; ++r) {
        if (r > 0) {
            out.push_back('\n');
        }
        const std::size_t rowStartOffset = rect.originOffset + r * rect.bytesPerRow;
        for (std::size_t c = 0; c < rect.width; ++c) {
            const std::size_t srcOffset = rowStartOffset + c;
            const std::uint8_t value = (bytes != nullptr && srcOffset < totalLength)
                ? bytes[srcOffset]
                : static_cast<std::uint8_t>(0);
            out.push_back((value >= 32 && value <= 126)
                          ? static_cast<char>(value)
                          : '.');
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

    // First pass: try to parse every line as hex. If any line fails, fall back to
    // raw-bytes mode (each line treated as its own byte sequence — the user pasted
    // plain ASCII, e.g. "abcd\nefgh", probably intending an ASCII rectangle).
    std::vector<std::vector<std::uint8_t>> rows;
    rows.reserve(lines.size());
    bool allHex = true;
    for (const auto &line : lines) {
        std::vector<std::uint8_t> rowBytes;
        if (!tryParseHexLine(line, rowBytes)) {
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

}
