#include "HexCore.h"

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <sstream>

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

std::string makeHexDump(const std::vector<std::uint8_t> &bytes, std::size_t totalLength)
{
    if (bytes.empty()) {
        return "The current document is empty.";
    }

    std::ostringstream output;
    output << std::hex << std::setfill('0');

    for (std::size_t offset = 0; offset < bytes.size(); offset += 16) {
        output << std::setw(8) << offset << "  ";

        std::string ascii;
        const std::size_t rowEnd = std::min(offset + 16, bytes.size());
        ascii.reserve(16);

        for (std::size_t index = offset; index < offset + 16; ++index) {
            if (index < rowEnd) {
                const std::uint8_t value = bytes[index];
                output << std::setw(2) << static_cast<unsigned int>(value) << ' ';
                ascii.push_back(std::isprint(static_cast<unsigned char>(value)) ? static_cast<char>(value) : '.');
            } else {
                output << "   ";
                ascii.push_back(' ');
            }

            if (index == offset + 7) {
                output << ' ';
            }
        }

        output << " |" << ascii << "|\n";
    }

    if (bytes.size() < totalLength) {
        output << "\nPreview truncated at " << std::dec << bytes.size() << " of " << totalLength << " bytes.";
    }

    return output.str();
}

}
