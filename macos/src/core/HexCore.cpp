#include "HexCore.h"

#include <algorithm>
#include <cctype>

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

}
