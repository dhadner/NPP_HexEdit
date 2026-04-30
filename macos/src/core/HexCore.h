#pragma once

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

struct ByteEditOperation {
    std::size_t offset = 0;
    std::size_t replacedByteCount = 0;
    std::vector<std::uint8_t> replacement;
    CursorState nextCursor;
};

int hexDigitValue(int codepoint);

bool isVisibleEditableOffset(const DocumentView &view, std::size_t offset);

CursorState clampCursor(CursorState cursor, const DocumentView &view);

CursorState moveCursor(const CursorState &cursor, long delta, const DocumentView &view);

CursorState cursorToLineStart(const CursorState &cursor);

CursorState cursorToLineEnd(const CursorState &cursor, const DocumentView &view);

CursorState cursorToDocumentStart(const CursorState &cursor);

CursorState cursorToDocumentEnd(const CursorState &cursor, const DocumentView &view);

CursorState navigateLeft(const CursorState &cursor, const DocumentView &view);

CursorState navigateRight(const CursorState &cursor, const DocumentView &view);

ByteRange selectedOrCurrentRange(const DocumentView &view, const CursorState &cursor, const Selection &selection);

bool planHexDigitEdit(const DocumentView &view,
                      const CursorState &cursor,
                      const Selection &selection,
                      int hexValue,
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

}
