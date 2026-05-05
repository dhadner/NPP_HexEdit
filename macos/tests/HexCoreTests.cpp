#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_assertions = 0;
int g_failures = 0;
const char *g_currentSuite = "<none>";

void hexExpectImpl(bool condition, const char *expr, const char *file, int line)
{
    ++g_assertions;
    if (!condition) {
        ++g_failures;
        std::fprintf(stderr, "FAIL [%s] %s:%d: %s\n", g_currentSuite, file, line, expr);
    }
}

template <typename A, typename B>
void hexExpectEqImpl(const A &lhs, const B &rhs, const char *lhsExpr, const char *rhsExpr, const char *file, int line)
{
    ++g_assertions;
    if (!(lhs == rhs)) {
        ++g_failures;
        std::fprintf(stderr, "FAIL [%s] %s:%d: %s == %s\n", g_currentSuite, file, line, lhsExpr, rhsExpr);
    }
}

#define HEX_EXPECT(cond) hexExpectImpl(static_cast<bool>(cond), #cond, __FILE__, __LINE__)
#define HEX_EXPECT_EQ(a, b) hexExpectEqImpl((a), (b), #a, #b, __FILE__, __LINE__)

using namespace hexedit;

DocumentView makeView(const std::vector<std::uint8_t> &bytes, std::size_t totalLength)
{
    DocumentView view;
    view.bytes = bytes.empty() ? nullptr : bytes.data();
    view.visibleByteCount = bytes.size();
    view.totalLength = totalLength;
    return view;
}

void testHexDigitValue()
{
    g_currentSuite = "hexDigitValue";
    HEX_EXPECT_EQ(hexDigitValue('0'), 0);
    HEX_EXPECT_EQ(hexDigitValue('9'), 9);
    HEX_EXPECT_EQ(hexDigitValue('A'), 10);
    HEX_EXPECT_EQ(hexDigitValue('F'), 15);
    HEX_EXPECT_EQ(hexDigitValue('a'), 10);
    HEX_EXPECT_EQ(hexDigitValue('f'), 15);
    HEX_EXPECT_EQ(hexDigitValue('g'), -1);
    HEX_EXPECT_EQ(hexDigitValue('G'), -1);
    HEX_EXPECT_EQ(hexDigitValue('@'), -1);
    HEX_EXPECT_EQ(hexDigitValue('/'), -1);
    HEX_EXPECT_EQ(hexDigitValue(0), -1);
    HEX_EXPECT_EQ(hexDigitValue(0x100), -1);
}

void testIsVisibleEditableOffset()
{
    g_currentSuite = "isVisibleEditableOffset";

    std::vector<std::uint8_t> fullBytes = { 0x10, 0x20, 0x30 };
    DocumentView fullView = makeView(fullBytes, 3);
    HEX_EXPECT(isVisibleEditableOffset(fullView, 0));
    HEX_EXPECT(isVisibleEditableOffset(fullView, 2));
    HEX_EXPECT(isVisibleEditableOffset(fullView, 3));
    HEX_EXPECT(!isVisibleEditableOffset(fullView, 4));

    std::vector<std::uint8_t> truncatedBytes(64, 0xAA);
    DocumentView truncatedView = makeView(truncatedBytes, 1024);
    HEX_EXPECT(isVisibleEditableOffset(truncatedView, 0));
    HEX_EXPECT(isVisibleEditableOffset(truncatedView, 63));
    HEX_EXPECT(!isVisibleEditableOffset(truncatedView, 64));
    HEX_EXPECT(!isVisibleEditableOffset(truncatedView, 1024));

    DocumentView emptyView = makeView({}, 0);
    HEX_EXPECT(isVisibleEditableOffset(emptyView, 0));
    HEX_EXPECT(!isVisibleEditableOffset(emptyView, 1));
}

void testClampCursor()
{
    g_currentSuite = "clampCursor";

    std::vector<std::uint8_t> bytes(10, 0);
    DocumentView view = makeView(bytes, 10);

    CursorState c;
    c.offset = 100;
    c.nibble = 7;
    CursorState clamped = clampCursor(c, view);
    HEX_EXPECT_EQ(clamped.offset, std::size_t(10));
    HEX_EXPECT_EQ(clamped.nibble, 1);

    c.offset = 5;
    c.nibble = -3;
    clamped = clampCursor(c, view);
    HEX_EXPECT_EQ(clamped.offset, std::size_t(5));
    HEX_EXPECT_EQ(clamped.nibble, 0);

    DocumentView truncated;
    truncated.visibleByteCount = 32;
    truncated.totalLength = 1024;
    c.offset = 100;
    c.nibble = 0;
    clamped = clampCursor(c, truncated);
    HEX_EXPECT_EQ(clamped.offset, std::size_t(32));
}

void testMoveCursor()
{
    g_currentSuite = "moveCursor";

    std::vector<std::uint8_t> bytes(32, 0);
    DocumentView view = makeView(bytes, 32);

    CursorState c;
    c.offset = 5;
    c.nibble = 1;

    CursorState moved = moveCursor(c, 1, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(6));
    HEX_EXPECT_EQ(moved.nibble, 0);

    moved = moveCursor(c, -1, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(4));
    HEX_EXPECT_EQ(moved.nibble, 0);

    moved = moveCursor(c, -100, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(0));

    moved = moveCursor(c, 1000, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(32));

    c.offset = 8;
    moved = moveCursor(c, -16, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(0));

    c.offset = 8;
    moved = moveCursor(c, 16, view);
    HEX_EXPECT_EQ(moved.offset, std::size_t(24));
}

void testLineNavigation()
{
    g_currentSuite = "cursorToLineStart/End";

    std::vector<std::uint8_t> bytes(40, 0);
    DocumentView view = makeView(bytes, 40);

    CursorState c;
    c.offset = 19;
    c.nibble = 1;

    CursorState start = cursorToLineStart(c);
    HEX_EXPECT_EQ(start.offset, std::size_t(16));
    HEX_EXPECT_EQ(start.nibble, 0);

    CursorState end = cursorToLineEnd(c, view);
    HEX_EXPECT_EQ(end.offset, std::size_t(31));
    HEX_EXPECT_EQ(end.nibble, 0);

    c.offset = 35;
    end = cursorToLineEnd(c, view);
    HEX_EXPECT_EQ(end.offset, std::size_t(40));

    c.offset = 0;
    start = cursorToLineStart(c);
    HEX_EXPECT_EQ(start.offset, std::size_t(0));
}

void testDocumentNavigation()
{
    g_currentSuite = "cursorToDocumentStart/End";

    std::vector<std::uint8_t> bytes(40, 0);
    DocumentView view = makeView(bytes, 40);

    CursorState c;
    c.offset = 25;
    c.nibble = 1;

    CursorState start = cursorToDocumentStart(c);
    HEX_EXPECT_EQ(start.offset, std::size_t(0));
    HEX_EXPECT_EQ(start.nibble, 0);

    CursorState end = cursorToDocumentEnd(c, view);
    HEX_EXPECT_EQ(end.offset, std::size_t(40));
    HEX_EXPECT_EQ(end.nibble, 0);

    DocumentView truncated;
    truncated.bytes = bytes.data();
    truncated.visibleByteCount = 10;
    truncated.totalLength = 1024;
    end = cursorToDocumentEnd(c, truncated);
    HEX_EXPECT_EQ(end.offset, std::size_t(10));
    HEX_EXPECT_EQ(end.nibble, 0);

    DocumentView empty = makeView({}, 0);
    end = cursorToDocumentEnd(c, empty);
    HEX_EXPECT_EQ(end.offset, std::size_t(0));
}

void testNavigateLeftRight()
{
    g_currentSuite = "navigateLeft/Right";

    std::vector<std::uint8_t> bytes(8, 0);
    DocumentView view = makeView(bytes, 8);

    CursorState c;
    c.offset = 3;
    c.nibble = 0;
    c.field = CursorField::Hex;

    CursorState right = navigateRight(c, view);
    HEX_EXPECT_EQ(right.offset, std::size_t(3));
    HEX_EXPECT_EQ(right.nibble, 1);

    right = navigateRight(right, view);
    HEX_EXPECT_EQ(right.offset, std::size_t(4));
    HEX_EXPECT_EQ(right.nibble, 0);

    CursorState left = navigateLeft(right, view);
    HEX_EXPECT_EQ(left.offset, std::size_t(3));
    HEX_EXPECT_EQ(left.nibble, 0);

    left = navigateLeft(left, view);
    HEX_EXPECT_EQ(left.offset, std::size_t(2));
    HEX_EXPECT_EQ(left.nibble, 0);

    c.offset = 0;
    c.nibble = 0;
    left = navigateLeft(c, view);
    HEX_EXPECT_EQ(left.offset, std::size_t(0));

    c.offset = 8;
    c.nibble = 0;
    right = navigateRight(c, view);
    HEX_EXPECT_EQ(right.offset, std::size_t(8));
    HEX_EXPECT_EQ(right.nibble, 0);

    c.offset = 5;
    c.nibble = 0;
    c.field = CursorField::Ascii;
    right = navigateRight(c, view);
    HEX_EXPECT_EQ(right.offset, std::size_t(6));
    HEX_EXPECT_EQ(right.nibble, 0);
    HEX_EXPECT(right.field == CursorField::Ascii);
}

void testSelectedOrCurrentRange()
{
    g_currentSuite = "selectedOrCurrentRange";

    std::vector<std::uint8_t> bytes(16, 0);
    DocumentView view = makeView(bytes, 16);

    CursorState cursor;
    cursor.offset = 5;
    Selection sel;

    ByteRange range = selectedOrCurrentRange(view, cursor, sel);
    HEX_EXPECT_EQ(range.offset, std::size_t(5));
    HEX_EXPECT_EQ(range.byteCount, std::size_t(1));

    cursor.offset = 16;
    range = selectedOrCurrentRange(view, cursor, sel);
    HEX_EXPECT_EQ(range.offset, std::size_t(16));
    HEX_EXPECT_EQ(range.byteCount, std::size_t(0));

    sel.start = 4;
    sel.end = 9;
    cursor.offset = 0;
    range = selectedOrCurrentRange(view, cursor, sel);
    HEX_EXPECT_EQ(range.offset, std::size_t(4));
    HEX_EXPECT_EQ(range.byteCount, std::size_t(5));
}

void testPlanHexDigitEdit()
{
    g_currentSuite = "planHexDigitEdit";

    std::vector<std::uint8_t> bytes = { 0xAB, 0xCD };
    DocumentView view = makeView(bytes, 2);

    CursorState cursor;
    cursor.offset = 0;
    cursor.nibble = 0;
    cursor.field = CursorField::Hex;
    Selection sel;

    ByteEditOperation op;
    HEX_EXPECT(planHexDigitEdit(view, cursor, sel, 0x3, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(0));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(1));
    HEX_EXPECT_EQ(op.replacement.size(), std::size_t(1));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>(0x3B));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(0));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 1);

    cursor.offset = 0;
    cursor.nibble = 1;
    HEX_EXPECT(planHexDigitEdit(view, cursor, sel, 0xF, op));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>(0xAF));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 0);

    cursor.offset = 2;
    cursor.nibble = 0;
    HEX_EXPECT(planHexDigitEdit(view, cursor, sel, 0x7, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(0));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>(0x70));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 1);

    cursor.offset = 0;
    cursor.nibble = 1;
    sel.start = 1;
    sel.end = 2;
    HEX_EXPECT(planHexDigitEdit(view, cursor, sel, 0x5, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(1));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>(0x5D));

    sel = Selection{};
    HEX_EXPECT(!planHexDigitEdit(view, cursor, sel, -1, op));
    HEX_EXPECT(!planHexDigitEdit(view, cursor, sel, 16, op));

    cursor.offset = 99;
    HEX_EXPECT(!planHexDigitEdit(view, cursor, sel, 0, op));

    DocumentView truncated;
    truncated.bytes = bytes.data();
    truncated.visibleByteCount = 2;
    truncated.totalLength = 1024;
    cursor.offset = 2;
    cursor.nibble = 0;
    HEX_EXPECT(!planHexDigitEdit(truncated, cursor, sel, 0, op));
}

void testPlanAsciiByteEdit()
{
    g_currentSuite = "planAsciiByteEdit";

    std::vector<std::uint8_t> bytes = { 0x41, 0x42 };
    DocumentView view = makeView(bytes, 2);

    CursorState cursor;
    cursor.offset = 1;
    cursor.field = CursorField::Ascii;
    Selection sel;

    ByteEditOperation op;
    HEX_EXPECT(planAsciiByteEdit(view, cursor, sel, 'Z', op));
    HEX_EXPECT_EQ(op.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(1));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>('Z'));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(2));
    HEX_EXPECT(op.nextCursor.field == CursorField::Ascii);

    cursor.offset = 2;
    HEX_EXPECT(planAsciiByteEdit(view, cursor, sel, '!', op));
    HEX_EXPECT_EQ(op.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(0));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>('!'));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(2));

    cursor.offset = 0;
    sel.start = 1;
    sel.end = 2;
    HEX_EXPECT(planAsciiByteEdit(view, cursor, sel, 'X', op));
    HEX_EXPECT_EQ(op.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(1));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(2));

    cursor.offset = 99;
    sel = Selection{};
    HEX_EXPECT(!planAsciiByteEdit(view, cursor, sel, 'A', op));
}

void testPlanDeleteEdit()
{
    g_currentSuite = "planDeleteEdit";

    std::vector<std::uint8_t> bytes = { 0x10, 0x20, 0x30, 0x40, 0x50 };
    DocumentView view = makeView(bytes, 5);

    CursorState cursor;
    cursor.offset = 2;
    Selection sel;

    ByteEditOperation op;

    HEX_EXPECT(planDeleteEdit(view, cursor, sel, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(1));
    HEX_EXPECT_EQ(op.replacement.size(), std::size_t(0));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 0);

    sel.start = 1;
    sel.end = 4;
    cursor.offset = 0;
    HEX_EXPECT(planDeleteEdit(view, cursor, sel, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(3));
    HEX_EXPECT_EQ(op.replacement.size(), std::size_t(0));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(1));

    sel = Selection{};
    cursor.offset = 5;
    HEX_EXPECT(!planDeleteEdit(view, cursor, sel, op));

    DocumentView empty = makeView({}, 0);
    cursor.offset = 0;
    HEX_EXPECT(!planDeleteEdit(empty, cursor, sel, op));
}

void testPlanPasteEdit()
{
    g_currentSuite = "planPasteEdit";

    std::vector<std::uint8_t> bytes = { 0x41, 0x42, 0x43, 0x44 };
    DocumentView view = makeView(bytes, 4);

    CursorState cursor;
    cursor.offset = 2;
    Selection sel;

    const std::uint8_t replacement[] = { 0xAA, 0xBB };
    ByteEditOperation op;

    HEX_EXPECT(planPasteEdit(view, cursor, sel, replacement, 2, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(2));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(0));
    HEX_EXPECT_EQ(op.replacement.size(), std::size_t(2));
    HEX_EXPECT_EQ(op.replacement[0], static_cast<std::uint8_t>(0xAA));
    HEX_EXPECT_EQ(op.replacement[1], static_cast<std::uint8_t>(0xBB));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(4));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 0);

    cursor.offset = 4;
    HEX_EXPECT(planPasteEdit(view, cursor, sel, replacement, 2, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(4));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(0));
    // Append at EOF: next-cursor would logically be 6 but clamps to old totalLength=4;
    // the adapter re-clamps with the new view post-apply.
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(4));

    sel.start = 1;
    sel.end = 3;
    cursor.offset = 0;
    HEX_EXPECT(planPasteEdit(view, cursor, sel, replacement, 2, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(1));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(2));
    HEX_EXPECT_EQ(op.nextCursor.offset, std::size_t(3));

    sel = Selection{};
    HEX_EXPECT(!planPasteEdit(view, cursor, sel, replacement, 0, op));
    HEX_EXPECT(!planPasteEdit(view, cursor, sel, nullptr, 1, op));

    DocumentView empty = makeView({}, 0);
    cursor.offset = 0;
    HEX_EXPECT(planPasteEdit(empty, cursor, sel, replacement, 2, op));
    HEX_EXPECT_EQ(op.offset, std::size_t(0));
    HEX_EXPECT_EQ(op.replacedByteCount, std::size_t(0));
    HEX_EXPECT_EQ(op.replacement.size(), std::size_t(2));
}

void testFormatHexClipboardText()
{
    g_currentSuite = "formatHexClipboardText";

    HEX_EXPECT_EQ(formatHexClipboardText(nullptr, 0), std::string());

    std::uint8_t empty = 0;
    HEX_EXPECT_EQ(formatHexClipboardText(&empty, 0), std::string());

    std::vector<std::uint8_t> single = { 0x00 };
    HEX_EXPECT_EQ(formatHexClipboardText(single.data(), single.size()), std::string("00"));

    std::vector<std::uint8_t> bytes = { 0xDE, 0xAD, 0xBE, 0xEF };
    HEX_EXPECT_EQ(formatHexClipboardText(bytes.data(), bytes.size()), std::string("de ad be ef"));

    std::vector<std::uint8_t> withZero = { 0x00, 0x10, 0xFF };
    HEX_EXPECT_EQ(formatHexClipboardText(withZero.data(), withZero.size()), std::string("00 10 ff"));
}

void testParseHexClipboardText()
{
    g_currentSuite = "parseHexClipboardText";

    std::vector<std::uint8_t> out;

    HEX_EXPECT(parseHexClipboardText("DE AD BE EF", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(4));
    if (out.size() == 4) {
        HEX_EXPECT_EQ(static_cast<int>(out[0]), 0xDE);
        HEX_EXPECT_EQ(static_cast<int>(out[1]), 0xAD);
        HEX_EXPECT_EQ(static_cast<int>(out[2]), 0xBE);
        HEX_EXPECT_EQ(static_cast<int>(out[3]), 0xEF);
    }

    HEX_EXPECT(parseHexClipboardText("deadbeef", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(4));
    if (out.size() == 4) {
        HEX_EXPECT_EQ(static_cast<int>(out[0]), 0xDE);
        HEX_EXPECT_EQ(static_cast<int>(out[3]), 0xEF);
    }

    HEX_EXPECT(parseHexClipboardText("DE  AD\tBE\nEF", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(4));

    HEX_EXPECT(parseHexClipboardText("0xDE 0xAD", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(2));

    HEX_EXPECT(parseHexClipboardText("DE,AD;BE:EF", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(4));

    HEX_EXPECT(!parseHexClipboardText("hello", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(0));

    HEX_EXPECT(!parseHexClipboardText("DEA", out));
    HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(0));

    HEX_EXPECT(!parseHexClipboardText("", out));
    HEX_EXPECT(!parseHexClipboardText("   \t\n", out));

    std::vector<std::uint8_t> roundTripIn = { 0x00, 0xFF, 0x42, 0x7F };
    std::string formatted = formatHexClipboardText(roundTripIn.data(), roundTripIn.size());
    HEX_EXPECT(parseHexClipboardText(formatted, out));
    HEX_EXPECT_EQ(out.size(), roundTripIn.size());
    if (out.size() == roundTripIn.size()) {
        for (std::size_t i = 0; i < out.size(); ++i) {
            HEX_EXPECT_EQ(static_cast<int>(out[i]), static_cast<int>(roundTripIn[i]));
        }
    }
}

void testViewModeShape()
{
    g_currentSuite = "viewModeShape";

    HEX_EXPECT(isValidBytesPerCell(1));
    HEX_EXPECT(isValidBytesPerCell(2));
    HEX_EXPECT(isValidBytesPerCell(4));
    HEX_EXPECT(isValidBytesPerCell(8));
    HEX_EXPECT(!isValidBytesPerCell(0));
    HEX_EXPECT(!isValidBytesPerCell(3));
    HEX_EXPECT(!isValidBytesPerCell(16));

    ViewMode hex8;
    HEX_EXPECT_EQ(digitsPerCell(hex8), 2);

    ViewMode hex16; hex16.bytesPerCell = 2;
    HEX_EXPECT_EQ(digitsPerCell(hex16), 4);

    ViewMode hex32; hex32.bytesPerCell = 4;
    HEX_EXPECT_EQ(digitsPerCell(hex32), 8);

    ViewMode hex64; hex64.bytesPerCell = 8;
    HEX_EXPECT_EQ(digitsPerCell(hex64), 16);

    ViewMode bin8; bin8.notation = CellNotation::Binary;
    HEX_EXPECT_EQ(digitsPerCell(bin8), 8);

    ViewMode bin16; bin16.bytesPerCell = 2; bin16.notation = CellNotation::Binary;
    HEX_EXPECT_EQ(digitsPerCell(bin16), 16);

    HEX_EXPECT_EQ(cellsPerRow(16, 1), 16);
    HEX_EXPECT_EQ(cellsPerRow(16, 2), 8);
    HEX_EXPECT_EQ(cellsPerRow(16, 4), 4);
    HEX_EXPECT_EQ(cellsPerRow(16, 8), 2);
    HEX_EXPECT_EQ(cellsPerRow(16, 3), 0);  // invalid bpc
    HEX_EXPECT_EQ(cellsPerRow(0, 1), 0);
}

void testFormatCell()
{
    g_currentSuite = "formatCell";

    std::vector<std::uint8_t> bytes = { 0x12, 0x34, 0x56, 0x78 };

    ViewMode hex8;
    HEX_EXPECT_EQ(formatCell(bytes.data(), 1, hex8), std::string("12"));

    ViewMode hex16; hex16.bytesPerCell = 2;
    HEX_EXPECT_EQ(formatCell(bytes.data(), 2, hex16), std::string("1234"));

    ViewMode hex16le; hex16le.bytesPerCell = 2; hex16le.littleEndian = true;
    HEX_EXPECT_EQ(formatCell(bytes.data(), 2, hex16le), std::string("3412"));

    ViewMode hex32; hex32.bytesPerCell = 4;
    HEX_EXPECT_EQ(formatCell(bytes.data(), 4, hex32), std::string("12345678"));

    ViewMode hex32le; hex32le.bytesPerCell = 4; hex32le.littleEndian = true;
    HEX_EXPECT_EQ(formatCell(bytes.data(), 4, hex32le), std::string("78563412"));

    ViewMode bin8; bin8.notation = CellNotation::Binary;
    std::vector<std::uint8_t> aa = { 0xAA };
    HEX_EXPECT_EQ(formatCell(aa.data(), 1, bin8), std::string("10101010"));

    ViewMode bin16le; bin16le.bytesPerCell = 2; bin16le.notation = CellNotation::Binary; bin16le.littleEndian = true;
    std::vector<std::uint8_t> ff00 = { 0xFF, 0x00 };
    HEX_EXPECT_EQ(formatCell(ff00.data(), 2, bin16le), std::string("0000000011111111"));

    // Partial cell at EOF — short bytes are rendered as spaces.
    ViewMode hex32be; hex32be.bytesPerCell = 4;
    std::vector<std::uint8_t> partial = { 0xAB, 0xCD };
    HEX_EXPECT_EQ(formatCell(partial.data(), 2, hex32be), std::string("abcd    "));
}

void testDisplayPositionMapping()
{
    g_currentSuite = "displayPositionMapping";

    ViewMode hex8;  // bpc=1, hex, BE
    DisplayPosition d = displayPositionForByte(5, 0, hex8);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(5));
    HEX_EXPECT_EQ(d.digitInCell, 0);
    d = displayPositionForByte(5, 1, hex8);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(5));
    HEX_EXPECT_EQ(d.digitInCell, 1);

    ViewMode hex16;  hex16.bytesPerCell = 2;
    // Byte 0 is at start of cell 0 (BE) — digit 0 (high nibble of byte 0).
    d = displayPositionForByte(0, 0, hex16);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(d.digitInCell, 0);
    // Byte 1 is the second byte of cell 0 (BE) — digit 2.
    d = displayPositionForByte(1, 0, hex16);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(d.digitInCell, 2);
    d = displayPositionForByte(1, 1, hex16);
    HEX_EXPECT_EQ(d.digitInCell, 3);

    ViewMode hex16le; hex16le.bytesPerCell = 2; hex16le.littleEndian = true;
    // Byte 0 in LE 16-bit appears as the SECOND byte in the cell (digits 2-3).
    d = displayPositionForByte(0, 0, hex16le);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(d.digitInCell, 2);
    d = displayPositionForByte(1, 0, hex16le);
    HEX_EXPECT_EQ(d.digitInCell, 0);  // Byte 1 displays first in LE.

    ViewMode bin8; bin8.notation = CellNotation::Binary;
    d = displayPositionForByte(3, 5, bin8);
    HEX_EXPECT_EQ(d.cellIndex, static_cast<std::size_t>(3));
    HEX_EXPECT_EQ(d.digitInCell, 5);

    // Round-trip: physical → display → physical
    for (int bpc : { 1, 2, 4, 8 }) {
        for (bool little : { false, true }) {
            ViewMode m; m.bytesPerCell = bpc; m.littleEndian = little;
            for (std::size_t b = 0; b < static_cast<std::size_t>(bpc * 3); ++b) {
                for (int n = 0; n < 2; ++n) {
                    DisplayPosition dp = displayPositionForByte(b, n, m);
                    PhysicalPosition pp = physicalPositionForDisplay(dp.cellIndex, dp.digitInCell, m);
                    HEX_EXPECT_EQ(pp.byteInRow, b);
                    HEX_EXPECT_EQ(pp.subInByte, n);
                }
            }
        }
    }
}

void testResolveGotoOffset()
{
    g_currentSuite = "resolveGotoOffset";

    std::size_t out = 0;

    // Decimal absolute.
    HEX_EXPECT(resolveGotoOffset("100", 50, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(100));

    // Hex absolute (lowercase).
    HEX_EXPECT(resolveGotoOffset("0x1f", 0, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(0x1F));

    // Hex absolute (uppercase prefix).
    HEX_EXPECT(resolveGotoOffset("0XAB", 0, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(0xAB));

    // Whitespace-tolerant.
    HEX_EXPECT(resolveGotoOffset("  0x1f  ", 0, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(0x1F));

    // Relative forward (decimal).
    HEX_EXPECT(resolveGotoOffset("+10", 100, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(110));

    // Relative forward (hex).
    HEX_EXPECT(resolveGotoOffset("+0x10", 100, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(116));

    // Relative backward.
    HEX_EXPECT(resolveGotoOffset("-50", 100, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(50));

    // Relative backward saturates at 0.
    HEX_EXPECT(resolveGotoOffset("-1000", 100, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(0));

    // Absolute beyond max clamps to totalLength.
    HEX_EXPECT(resolveGotoOffset("99999", 0, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(1024));

    // Relative forward beyond max clamps.
    HEX_EXPECT(resolveGotoOffset("+99999", 100, 1024, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(1024));

    // Underscore / comma digit separators are accepted.
    HEX_EXPECT(resolveGotoOffset("1_000", 0, 10000, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(1000));
    HEX_EXPECT(resolveGotoOffset("0xFF,FF", 0, 0x100000, out));
    HEX_EXPECT_EQ(out, static_cast<std::size_t>(0xFFFF));

    // Empty input rejected.
    HEX_EXPECT(!resolveGotoOffset("", 0, 1024, out));
    HEX_EXPECT(!resolveGotoOffset("   ", 0, 1024, out));

    // Sign with no digits rejected.
    HEX_EXPECT(!resolveGotoOffset("+", 0, 1024, out));
    HEX_EXPECT(!resolveGotoOffset("-0x", 0, 1024, out));

    // Garbage rejected.
    HEX_EXPECT(!resolveGotoOffset("abc", 0, 1024, out));   // 'b','c' invalid in decimal
    HEX_EXPECT(!resolveGotoOffset("0xZZ", 0, 1024, out));
    HEX_EXPECT(!resolveGotoOffset("12.3", 0, 1024, out));
}

void testParseSearchPattern()
{
    g_currentSuite = "parseSearchPattern";

    SearchPattern p;

    // ASCII fallback (plain text).
    HEX_EXPECT(parseSearchPattern("hello", true, p));
    HEX_EXPECT_EQ(static_cast<int>(p.kind), static_cast<int>(SearchPatternKind::Ascii));
    HEX_EXPECT_EQ(p.bytes.size(), static_cast<std::size_t>(5));
    HEX_EXPECT_EQ(static_cast<int>(p.bytes[0]), static_cast<int>('h'));
    HEX_EXPECT(p.matchCase);

    // Hex via "0x" prefix.
    HEX_EXPECT(parseSearchPattern("0xDEADBEEF", true, p));
    HEX_EXPECT_EQ(static_cast<int>(p.kind), static_cast<int>(SearchPatternKind::Hex));
    HEX_EXPECT_EQ(p.bytes.size(), static_cast<std::size_t>(4));
    HEX_EXPECT_EQ(static_cast<int>(p.bytes[0]), 0xDE);
    HEX_EXPECT_EQ(static_cast<int>(p.bytes[3]), 0xEF);

    // Hex via space-separated digits with at least one a-f.
    HEX_EXPECT(parseSearchPattern("de ad be ef", true, p));
    HEX_EXPECT_EQ(static_cast<int>(p.kind), static_cast<int>(SearchPatternKind::Hex));
    HEX_EXPECT_EQ(p.bytes.size(), static_cast<std::size_t>(4));

    // All-digit numeric strings stay as ASCII (would otherwise mis-detect as hex).
    HEX_EXPECT(parseSearchPattern("1234", true, p));
    HEX_EXPECT_EQ(static_cast<int>(p.kind), static_cast<int>(SearchPatternKind::Ascii));
    HEX_EXPECT_EQ(p.bytes.size(), static_cast<std::size_t>(4));

    // Match-case off propagates.
    HEX_EXPECT(parseSearchPattern("Hi", false, p));
    HEX_EXPECT(!p.matchCase);

    // Empty rejected.
    HEX_EXPECT(!parseSearchPattern("", true, p));
}

void testFindBytePattern()
{
    g_currentSuite = "findBytePattern";

    std::vector<std::uint8_t> hay = {
        'A','B','C','D','E','F','G','H','A','B','C','D','E','F','G','H'
    };
    SpanByteSource haySrc(hay.data(), hay.size());
    std::size_t at = 0;

    SearchPattern needle;
    HEX_EXPECT(parseSearchPattern("CD", true, needle));

    // Forward from 0 finds first occurrence at offset 2.
    HEX_EXPECT(findBytePattern(haySrc, needle, 0,
                                SearchDirection::Forward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(2));

    // Forward from 3 finds the second at offset 10.
    HEX_EXPECT(findBytePattern(haySrc, needle, 3,
                                SearchDirection::Forward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(10));

    // Forward from 11 with wrap → wraps to offset 2.
    HEX_EXPECT(findBytePattern(haySrc, needle, 11,
                                SearchDirection::Forward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(2));

    // Forward from 11 without wrap → no match.
    HEX_EXPECT(!findBytePattern(haySrc, needle, 11,
                                 SearchDirection::Forward, false, at));

    // Backward from end (16) finds the second at offset 10.
    HEX_EXPECT(findBytePattern(haySrc, needle, 16,
                                SearchDirection::Backward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(10));

    // Backward from offset 5 finds the first at offset 2.
    HEX_EXPECT(findBytePattern(haySrc, needle, 5,
                                SearchDirection::Backward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(2));

    // Backward from 1 with wrap → wraps to offset 10 (last in document).
    HEX_EXPECT(findBytePattern(haySrc, needle, 1,
                                SearchDirection::Backward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(10));

    // Backward from 1 without wrap → no match.
    HEX_EXPECT(!findBytePattern(haySrc, needle, 1,
                                 SearchDirection::Backward, false, at));

    // Hex pattern search.
    std::vector<std::uint8_t> blob = { 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00 };
    SpanByteSource blobSrc(blob.data(), blob.size());
    SearchPattern hexNeedle;
    HEX_EXPECT(parseSearchPattern("0xDEADBEEF", true, hexNeedle));
    HEX_EXPECT(findBytePattern(blobSrc, hexNeedle, 0,
                                SearchDirection::Forward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(1));

    // Match case off finds 'CD' regardless of case.
    SearchPattern caseLess;
    HEX_EXPECT(parseSearchPattern("cd", false, caseLess));
    HEX_EXPECT(findBytePattern(haySrc, caseLess, 0,
                                SearchDirection::Forward, true, at));
    HEX_EXPECT_EQ(at, static_cast<std::size_t>(2));

    // Pattern longer than haystack → no match.
    SearchPattern bigNeedle;
    bigNeedle.bytes = std::vector<std::uint8_t>(100, 0x00);
    HEX_EXPECT(!findBytePattern(haySrc, bigNeedle, 0,
                                 SearchDirection::Forward, true, at));

    // Streaming-search regression: pattern lives at a chunk boundary.
    // kSearchChunkSize is 64 KB; build a haystack with the needle straddling
    // offset 64 KB - 2 to verify the overlap region catches it.
    {
        constexpr std::size_t kChunk = 64 * 1024;
        std::vector<std::uint8_t> bigHay(kChunk + 16, 0x00);
        const std::vector<std::uint8_t> longNeedle = { 0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD };
        const std::size_t plantOffset = kChunk - 2;
        std::copy(longNeedle.begin(), longNeedle.end(), bigHay.begin() + plantOffset);
        SpanByteSource bigSrc(bigHay.data(), bigHay.size());
        SearchPattern straddler;
        straddler.bytes = longNeedle;
        straddler.kind = SearchPatternKind::Hex;
        HEX_EXPECT(findBytePattern(bigSrc, straddler, 0,
                                    SearchDirection::Forward, false, at));
        HEX_EXPECT_EQ(at, plantOffset);

        // Same haystack, backward search starting from end — should find the
        // same plant via the backward chunked walk.
        HEX_EXPECT(findBytePattern(bigSrc, straddler, bigHay.size(),
                                    SearchDirection::Backward, false, at));
        HEX_EXPECT_EQ(at, plantOffset);
    }
}

void testClampCursorMode()
{
    g_currentSuite = "clampCursor (mode-aware)";

    std::vector<std::uint8_t> bytes(8, 0x00);
    DocumentView view = makeView(bytes, 8);

    CursorState c;
    c.offset = 3;

    ViewMode hex;
    c.nibble = 9;
    CursorState clamped = clampCursor(c, view, hex);
    HEX_EXPECT_EQ(clamped.nibble, 1);  // hex max = 1

    ViewMode bin;
    bin.notation = CellNotation::Binary;
    c.nibble = 9;
    clamped = clampCursor(c, view, bin);
    HEX_EXPECT_EQ(clamped.nibble, 7);  // binary max = 7

    c.nibble = -3;
    clamped = clampCursor(c, view, bin);
    HEX_EXPECT_EQ(clamped.nibble, 0);
}

void testPlanBitEdit()
{
    g_currentSuite = "planBitEdit";

    std::vector<std::uint8_t> bytes = { 0x00, 0xFF, 0xAA };
    DocumentView view = makeView(bytes, bytes.size());
    Selection none;

    // Set bit 0 (MSB) of byte 0 from 0 → 1.
    CursorState c;
    c.offset = 0;
    c.nibble = 0;
    ByteEditOperation op;
    HEX_EXPECT(planBitEdit(view, c, none, 1, op));
    HEX_EXPECT_EQ(op.offset, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(op.replacedByteCount, static_cast<std::size_t>(1));
    HEX_EXPECT_EQ(op.replacement.size(), static_cast<std::size_t>(1));
    HEX_EXPECT_EQ(static_cast<int>(op.replacement[0]), 0x80);  // MSB set
    HEX_EXPECT_EQ(op.nextCursor.offset, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(op.nextCursor.nibble, 1);  // advance to bit 1

    // Clear bit 7 (LSB) of byte 1 from 1 → 0.
    c.offset = 1;
    c.nibble = 7;
    HEX_EXPECT(planBitEdit(view, c, none, 0, op));
    HEX_EXPECT_EQ(static_cast<int>(op.replacement[0]), 0xFE);  // LSB cleared
    HEX_EXPECT_EQ(op.nextCursor.offset, static_cast<std::size_t>(2));  // rolled to next byte
    HEX_EXPECT_EQ(op.nextCursor.nibble, 0);

    // Setting an already-set bit is a no-op for the bit value but still produces a write.
    c.offset = 1;
    c.nibble = 4;
    HEX_EXPECT(planBitEdit(view, c, none, 1, op));
    HEX_EXPECT_EQ(static_cast<int>(op.replacement[0]), 0xFF);

    // Toggle bit 1 of byte 2 (0xAA = 10101010, bit 1 = '0' → '1').
    c.offset = 2;
    c.nibble = 1;
    HEX_EXPECT(planBitEdit(view, c, none, 1, op));
    HEX_EXPECT_EQ(static_cast<int>(op.replacement[0]), 0xEA);  // 11101010

    // Append at EOF — empty doc + bit 3 set → 0x10.
    std::vector<std::uint8_t> empty;
    DocumentView emptyView = makeView(empty, 0);
    c.offset = 0;
    c.nibble = 3;
    HEX_EXPECT(planBitEdit(emptyView, c, none, 1, op));
    HEX_EXPECT_EQ(op.replacedByteCount, static_cast<std::size_t>(0));
    HEX_EXPECT_EQ(static_cast<int>(op.replacement[0]), 0x10);

    // Invalid bit value rejected.
    c.offset = 0;
    c.nibble = 0;
    HEX_EXPECT(!planBitEdit(view, c, none, 2, op));
    HEX_EXPECT(!planBitEdit(view, c, none, -1, op));

    // Out-of-range bit index rejected.
    c.offset = 0;
    c.nibble = 8;
    HEX_EXPECT(!planBitEdit(view, c, none, 1, op));
}

void testNavigateInDisplayOrder()
{
    g_currentSuite = "navigateLeft/Right (display-order)";

    std::vector<std::uint8_t> bytes(32, 0x00);
    DocumentView view = makeView(bytes, 32);

    // Default 8-Bit hex big-endian — should match the old byte-order overloads.
    {
        ViewMode m;  // bpc=1, hex, BE
        const int bpr = 16;
        CursorState c; c.offset = 4; c.nibble = 0;
        CursorState next = navigateRight(c, view, m, bpr);
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(next.nibble, 1);

        next = navigateRight(next, view, m, bpr);
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(5));
        HEX_EXPECT_EQ(next.nibble, 0);

        next = navigateLeft(next, view, m, bpr);
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(next.nibble, 1);
    }

    // 16-Bit hex little-endian — the cell holds bytes (0,1) but byte 1 displays first.
    // Starting at byte 0 nibble 0 (cell 0 digit 2), navigateRight should go to nibble 1
    // (cell 0 digit 3); the next one should jump to byte 3 nibble 0 (cell 1 digit 0,
    // because cell 1 in LE displays byte 3 first).
    {
        ViewMode m; m.bytesPerCell = 2; m.littleEndian = true;
        const int bpr = 16;  // 8 cells × 2 bytes
        CursorState c; c.offset = 0; c.nibble = 0;

        // Verify the starting display position is digit 2 (= second byte of cell 0).
        DisplayPosition dp = displayPositionForByte(0, 0, m);
        HEX_EXPECT_EQ(dp.cellIndex, static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(dp.digitInCell, 2);

        CursorState next = navigateRight(c, view, m, bpr);
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(next.nibble, 1);  // byte 0 low nibble (cell 0 digit 3)

        next = navigateRight(next, view, m, bpr);
        // cell 0 digit 4 → cell 1 digit 0 → physical = byte 3 high nibble.
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(next.nibble, 0);

        // Going back should retrace: byte 0 nibble 1.
        CursorState back = navigateLeft(next, view, m, bpr);
        HEX_EXPECT_EQ(back.offset, static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(back.nibble, 1);
    }

    // Row-boundary advance in BE 8-bit: navigateRight at end of row 0 jumps to row 1.
    {
        ViewMode m;  // bpc=1
        const int bpr = 16;
        CursorState c; c.offset = 15; c.nibble = 1;
        CursorState next = navigateRight(c, view, m, bpr);
        HEX_EXPECT_EQ(next.offset, static_cast<std::size_t>(16));
        HEX_EXPECT_EQ(next.nibble, 0);
    }

    // Row-boundary retreat in BE 8-bit.
    {
        ViewMode m;
        const int bpr = 16;
        CursorState c; c.offset = 16; c.nibble = 0;
        CursorState back = navigateLeft(c, view, m, bpr);
        HEX_EXPECT_EQ(back.offset, static_cast<std::size_t>(15));
        HEX_EXPECT_EQ(back.nibble, 1);
    }

    // navigateLeft from document start is a no-op.
    {
        ViewMode m;
        const int bpr = 16;
        CursorState c; c.offset = 0; c.nibble = 0;
        CursorState back = navigateLeft(c, view, m, bpr);
        HEX_EXPECT_EQ(back.offset, static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(back.nibble, 0);
    }
}

void testComputeByteDiffs()
{
    g_currentSuite = "computeByteDiffs";

    auto src = [](const std::vector<std::uint8_t> &v) {
        return SpanByteSource(v.data(), v.size());
    };

    // Identical buffers → empty mask.
    std::vector<std::uint8_t> same1 = { 0x01, 0x02, 0x03 };
    std::vector<std::uint8_t> same2 = { 0x01, 0x02, 0x03 };
    auto mask = computeByteDiffs(src(same1), src(same2));
    HEX_EXPECT(mask.empty());

    // Single byte differs.
    std::vector<std::uint8_t> a = { 0x01, 0x02, 0x03, 0x04 };
    std::vector<std::uint8_t> b = { 0x01, 0x02, 0xFF, 0x04 };
    mask = computeByteDiffs(src(a), src(b));
    HEX_EXPECT_EQ(mask.size(), static_cast<std::size_t>(4));
    HEX_EXPECT(!mask[0]);
    HEX_EXPECT(!mask[1]);
    HEX_EXPECT(mask[2]);
    HEX_EXPECT(!mask[3]);

    // Different lengths — extra bytes count as differing.
    std::vector<std::uint8_t> shorter = { 0x01, 0x02 };
    std::vector<std::uint8_t> longer  = { 0x01, 0x02, 0x03, 0x04 };
    mask = computeByteDiffs(src(shorter), src(longer));
    HEX_EXPECT_EQ(mask.size(), static_cast<std::size_t>(4));
    HEX_EXPECT(!mask[0]);
    HEX_EXPECT(!mask[1]);
    HEX_EXPECT(mask[2]);
    HEX_EXPECT(mask[3]);

    // Reverse order of args yields the same mask.
    mask = computeByteDiffs(src(longer), src(shorter));
    HEX_EXPECT_EQ(mask.size(), static_cast<std::size_t>(4));
    HEX_EXPECT(!mask[0]);
    HEX_EXPECT(mask[2]);
    HEX_EXPECT(mask[3]);

    // Empty sources.
    SpanByteSource empty(nullptr, 0);
    mask = computeByteDiffs(empty, empty);
    HEX_EXPECT(mask.empty());

    // One side empty, other has content → all bytes differ.
    mask = computeByteDiffs(empty, src(longer));
    HEX_EXPECT_EQ(mask.size(), static_cast<std::size_t>(4));
    for (std::size_t i = 0; i < mask.size(); ++i) {
        HEX_EXPECT(mask[i]);
    }

    // Same length, all bytes differ.
    std::vector<std::uint8_t> p = { 0x00, 0x00, 0x00 };
    std::vector<std::uint8_t> q = { 0xFF, 0xFF, 0xFF };
    mask = computeByteDiffs(src(p), src(q));
    HEX_EXPECT_EQ(mask.size(), static_cast<std::size_t>(3));
    for (std::size_t i = 0; i < mask.size(); ++i) {
        HEX_EXPECT(mask[i]);
    }
}

void testMakeRectSelection()
{
    g_currentSuite = "makeRectSelection";

    // Anchor and end on same byte → 1×1 rectangle.
    {
        const RectSelection r = makeRectSelection(/*anchor*/ 5, /*end*/ 5, /*bpr*/ 16, /*total*/ 256);
        HEX_EXPECT(r.active());
        HEX_EXPECT_EQ(r.originOffset, static_cast<std::size_t>(5));
        HEX_EXPECT_EQ(r.width, static_cast<std::size_t>(1));
        HEX_EXPECT_EQ(r.height, static_cast<std::size_t>(1));
        HEX_EXPECT_EQ(r.bytesPerRow, static_cast<std::size_t>(16));
    }

    // Top-left → bottom-right: anchor=0x12 end=0x35, bpr=16
    //   anchorRow=1 anchorCol=2, endRow=3 endCol=5 → origin=18, width=4, height=3.
    {
        const RectSelection r = makeRectSelection(0x12, 0x35, 16, 256);
        HEX_EXPECT_EQ(r.originOffset, static_cast<std::size_t>(0x12));
        HEX_EXPECT_EQ(r.width, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(r.height, static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(r.totalBytes(), static_cast<std::size_t>(12));
    }

    // Bottom-right → top-left: same rectangle when corners reversed.
    {
        const RectSelection r = makeRectSelection(0x35, 0x12, 16, 256);
        HEX_EXPECT_EQ(r.originOffset, static_cast<std::size_t>(0x12));
        HEX_EXPECT_EQ(r.width, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(r.height, static_cast<std::size_t>(3));
    }

    // Bottom-left → top-right: still normalises to the same rectangle.
    //   anchor=0x32 (row 3, col 2), end=0x15 (row 1, col 5) → rows[1..3], cols[2..5]
    {
        const RectSelection r = makeRectSelection(0x32, 0x15, 16, 256);
        HEX_EXPECT_EQ(r.originOffset, static_cast<std::size_t>(0x12));
        HEX_EXPECT_EQ(r.width, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(r.height, static_cast<std::size_t>(3));
    }

    // Both offsets clamped past EOF → still produce a valid rectangle anchored at end.
    {
        const RectSelection r = makeRectSelection(/*anchor*/ 1000, /*end*/ 2000, /*bpr*/ 16, /*total*/ 100);
        // anchor and end both clamp to 100. row=6 col=4 → 1×1 rect at offset 100 (one past EOF).
        HEX_EXPECT(r.active());
        HEX_EXPECT_EQ(r.originOffset, static_cast<std::size_t>(100));
    }

    // bytesPerRow = 0 → inactive rectangle (defensive).
    {
        const RectSelection r = makeRectSelection(0, 10, 0, 100);
        HEX_EXPECT(!r.active());
    }
}

void testRectToRanges()
{
    g_currentSuite = "rectToRanges";

    // 4×3 rectangle, fully inside file → 3 equal-width ranges.
    {
        const RectSelection rect = makeRectSelection(0x12, 0x35, 16, 256);
        const auto ranges = rectToRanges(rect, 256);
        HEX_EXPECT_EQ(ranges.size(), static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(ranges[0].offset, static_cast<std::size_t>(0x12));
        HEX_EXPECT_EQ(ranges[0].byteCount, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(ranges[1].offset, static_cast<std::size_t>(0x22));
        HEX_EXPECT_EQ(ranges[1].byteCount, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(ranges[2].offset, static_cast<std::size_t>(0x32));
        HEX_EXPECT_EQ(ranges[2].byteCount, static_cast<std::size_t>(4));
    }

    // Last row clipped because the rect runs past EOF. Built directly (not via
    // makeRectSelection, which would clamp the corners and collapse the rectangle).
    //   3 rows × 4 wide starting at offset 0 with file length 10: row 2 offset=8, take=2.
    {
        RectSelection rect;
        rect.originOffset = 0;
        rect.width = 4;
        rect.height = 3;
        rect.bytesPerRow = 4;
        const auto ranges = rectToRanges(rect, 10);
        HEX_EXPECT_EQ(ranges.size(), static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(ranges[0].byteCount, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(ranges[1].byteCount, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(ranges[2].offset, static_cast<std::size_t>(8));
        HEX_EXPECT_EQ(ranges[2].byteCount, static_cast<std::size_t>(2));
    }

    // First row already past EOF → empty result (extreme case after file truncation).
    {
        RectSelection rect;
        rect.originOffset = 100;
        rect.width = 4;
        rect.height = 2;
        rect.bytesPerRow = 16;
        const auto ranges = rectToRanges(rect, 50);
        HEX_EXPECT_EQ(ranges.size(), static_cast<std::size_t>(0));
    }

    // Inactive rect → empty.
    {
        const auto ranges = rectToRanges(RectSelection{}, 100);
        HEX_EXPECT_EQ(ranges.size(), static_cast<std::size_t>(0));
    }
}

void testExtractRectBytes()
{
    g_currentSuite = "extractRectBytes";

    // Source: 16 bytes, all distinct values 0x10 .. 0x1F across 1 row of bpr=16.
    // We build a 4x3 rect at (col 2, row 0) but with bpr=8 so it spans rows 0..2.
    // Row 0 bytes: 10..17, Row 1: 18..1F, Row 2: 00..00 (out of range).
    {
        std::vector<std::uint8_t> src(16);
        for (std::size_t i = 0; i < 16; ++i) src[i] = static_cast<std::uint8_t>(0x10 + i);
        SpanByteSource srcS(src.data(), src.size());
        RectSelection rect;
        rect.originOffset = 2;     // row 0 col 2
        rect.width = 4;
        rect.height = 3;
        rect.bytesPerRow = 8;
        std::vector<std::uint8_t> out;
        HEX_EXPECT(extractRectBytes(srcS, rect, out));
        // Row 0 cols 2..5 → 0x12 0x13 0x14 0x15
        HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(12));
        HEX_EXPECT_EQ(out[0], static_cast<std::uint8_t>(0x12));
        HEX_EXPECT_EQ(out[3], static_cast<std::uint8_t>(0x15));
        // Row 1 cols 2..5 → 0x1A 0x1B 0x1C 0x1D
        HEX_EXPECT_EQ(out[4], static_cast<std::uint8_t>(0x1A));
        HEX_EXPECT_EQ(out[7], static_cast<std::uint8_t>(0x1D));
        // Row 2 entirely past EOF (offset 16+ ≥ totalLength 16) → zero-filled.
        HEX_EXPECT_EQ(out[8], static_cast<std::uint8_t>(0));
        HEX_EXPECT_EQ(out[11], static_cast<std::uint8_t>(0));
    }

    // Inactive rect → returns false, out untouched.
    {
        std::vector<std::uint8_t> out{0xAA, 0xBB};
        SpanByteSource emptySrc(nullptr, 0);
        HEX_EXPECT(!extractRectBytes(emptySrc, RectSelection{}, out));
        HEX_EXPECT_EQ(out.size(), static_cast<std::size_t>(2));
    }
}

void testFormatRectClipboardHex()
{
    g_currentSuite = "formatRectClipboardHex";

    // 2x2 rect of {DE AD, BE EF} → "DE AD\nBE EF"
    {
        std::vector<std::uint8_t> src = {0xDE, 0xAD, 0x00, 0x00, 0xBE, 0xEF};
        SpanByteSource srcS(src.data(), src.size());
        RectSelection rect;
        rect.originOffset = 0;
        rect.width = 2;
        rect.height = 2;
        rect.bytesPerRow = 4;
        const std::string text = formatRectClipboardHex(srcS, rect);
        HEX_EXPECT(text == "DE AD\nBE EF");
    }

    // Past-EOF row pads with zeros.
    {
        std::vector<std::uint8_t> src = {0xDE, 0xAD};
        SpanByteSource srcS(src.data(), src.size());
        RectSelection rect;
        rect.originOffset = 0;
        rect.width = 2;
        rect.height = 2;
        rect.bytesPerRow = 2;
        const std::string text = formatRectClipboardHex(srcS, rect);
        HEX_EXPECT(text == "DE AD\n00 00");
    }
}

void testParseRectClipboardText()
{
    g_currentSuite = "parseRectClipboardText";

    // Hex with spaces — 2x2.
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText("DE AD\nBE EF", bytes, w, h));
        HEX_EXPECT_EQ(w, static_cast<std::size_t>(2));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(2));
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0xDE));
        HEX_EXPECT_EQ(bytes[3], static_cast<std::uint8_t>(0xEF));
    }

    // No-separator hex — 4x1 from "DEADBEEF".
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText("DEADBEEF", bytes, w, h));
        HEX_EXPECT_EQ(w, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(1));
        HEX_EXPECT_EQ(bytes[2], static_cast<std::uint8_t>(0xBE));
    }

    // ASCII fallback when any line fails hex parse — width = char count, raw bytes.
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText("abcd\nefgh", bytes, w, h));
        HEX_EXPECT_EQ(w, static_cast<std::size_t>(4));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(2));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>('a'));
        HEX_EXPECT_EQ(bytes[7], static_cast<std::uint8_t>('h'));
    }

    // Mixed-width rows in hex mode → reject (shape mismatch).
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(!parseRectClipboardText("DE AD\nBE", bytes, w, h));
    }

    // CRLF tolerated.
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText("DE AD\r\nBE EF\r\n", bytes, w, h));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(2));
    }

    // Empty / blank input → reject.
    {
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(!parseRectClipboardText("", bytes, w, h));
        HEX_EXPECT(!parseRectClipboardText("\n\n", bytes, w, h));
    }
}

void testRectPayloadCodecRoundTrip()
{
    g_currentSuite = "rectPayloadCodecRoundTrip";

    // Round-trip with non-empty data.
    {
        const std::uint8_t data[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02};
        const auto payload = encodeRectPayload(RectClipboardKind::Bytes, 3, 2, data, 6);
        HEX_EXPECT_EQ(payload.size(), kRectPayloadHeaderSize + 6);
        RectPayload decoded;
        HEX_EXPECT(decodeRectPayload(payload.data(), payload.size(), decoded));
        HEX_EXPECT(decoded.kind == RectClipboardKind::Bytes);
        HEX_EXPECT_EQ(decoded.width, static_cast<std::uint32_t>(3));
        HEX_EXPECT_EQ(decoded.height, static_cast<std::uint32_t>(2));
        HEX_EXPECT_EQ(decoded.dataLength, static_cast<std::uint32_t>(6));
        HEX_EXPECT_EQ(decoded.data[0], static_cast<std::uint8_t>(0xDE));
        HEX_EXPECT_EQ(decoded.data[5], static_cast<std::uint8_t>(0x02));
    }

    // Empty-data round-trip with kind=Ascii (no payload bytes — width/height-only header).
    {
        const auto payload = encodeRectPayload(RectClipboardKind::Ascii, 1, 4, nullptr, 0);
        HEX_EXPECT_EQ(payload.size(), kRectPayloadHeaderSize);
        RectPayload decoded;
        HEX_EXPECT(decodeRectPayload(payload.data(), payload.size(), decoded));
        HEX_EXPECT(decoded.kind == RectClipboardKind::Ascii);
        HEX_EXPECT_EQ(decoded.dataLength, static_cast<std::uint32_t>(0));
        HEX_EXPECT(decoded.data == nullptr);
    }
}

void testStripHexDumpAddressAndAscii()
{
    g_currentSuite = "stripHexDumpAddressAndAscii";

    // No-address bare bytes pass through unchanged (modulo \r trim + brace strip).
    HEX_EXPECT(stripHexDumpAddressAndAscii("DE AD BE EF") == "DE AD BE EF");
    HEX_EXPECT(stripHexDumpAddressAndAscii("DEADBEEF") == "DEADBEEF");

    // CR trim — CRLF clipboards land here line-by-line.
    HEX_EXPECT(stripHexDumpAddressAndAscii("DE AD\r") == "DE AD");

    // lldb format: "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!...."
    {
        const std::string in = "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!....";
        const std::string out = stripHexDumpAddressAndAscii(in);
        // Address + ":" stripped; ASCII column after 2-space gap stripped.
        HEX_EXPECT(out.find("Hello") == std::string::npos);
        HEX_EXPECT(out.find("0x100000000") == std::string::npos);
        // The 16 byte tokens should remain.
        HEX_EXPECT(out.find("48 65") != std::string::npos);
        HEX_EXPECT(out.find("00 00 00") != std::string::npos);
    }

    // gdb format: per-byte 0x prefixes, address + colon.
    {
        const std::string in = "0x7fff5fbff8c0: 0x48    0x65    0x6c    0x6c";
        const std::string out = stripHexDumpAddressAndAscii(in);
        HEX_EXPECT(out.find("0x7fff5fbff8c0") == std::string::npos);
        // Per-byte 0x prefixes are NOT stripped here — the byte parser handles them.
        HEX_EXPECT(out.find("0x48") != std::string::npos);
    }

    // x64dbg format: address, pipe separator, bytes, ASCII gloss.
    {
        const std::string in = "00007FF6BC471000 | 48 65 6C 6C 6F 20 57 6F  Hello Wo";
        const std::string out = stripHexDumpAddressAndAscii(in);
        HEX_EXPECT(out.find("00007FF6BC471000") == std::string::npos);
        HEX_EXPECT(out.find("Hello") == std::string::npos);
        HEX_EXPECT(out.find("48 65") != std::string::npos);
    }

    // xxd format: address with concatenated hex bytes + ASCII gloss after 2 spaces.
    {
        const std::string in = "00000000: 4865 6c6c 6f20 776f  Hello wo";
        const std::string out = stripHexDumpAddressAndAscii(in);
        HEX_EXPECT(out.find("00000000:") == std::string::npos);
        HEX_EXPECT(out.find("Hello wo") == std::string::npos);
        HEX_EXPECT(out.find("4865") != std::string::npos);
    }

    // IDA segment:offset form treated as part of address.
    {
        const std::string in = "0001:0000  48 65 6C 6C 6F";
        const std::string out = stripHexDumpAddressAndAscii(in);
        HEX_EXPECT(out.find("0001:0000") == std::string::npos);
        HEX_EXPECT(out.find("48 65") != std::string::npos);
    }

    // C escape sequence: \x prefix becomes whitespace so tokens split.
    {
        const std::string out = stripHexDumpAddressAndAscii("\\x48\\x65\\x6c\\x6c");
        HEX_EXPECT(out.find("\\") == std::string::npos);
        HEX_EXPECT(out.find("48") != std::string::npos);
        HEX_EXPECT(out.find("65") != std::string::npos);
    }

    // C array literal: braces and 0x prefixes preserved (parser handles 0x).
    {
        const std::string out = stripHexDumpAddressAndAscii("{ 0x48, 0x65, 0x6c, 0x6c }");
        HEX_EXPECT(out.find('{') == std::string::npos);
        HEX_EXPECT(out.find('}') == std::string::npos);
        HEX_EXPECT(out.find("0x48") != std::string::npos);
    }

    // Negative case: lines that look hex-only must NOT be treated as having
    // an address. "DEADBEEF cafebabe" is two 8-char tokens of bytes, not
    // "DEADBEEF (addr) cafebabe (data)".
    {
        const std::string out = stripHexDumpAddressAndAscii("DEADBEEF cafebabe");
        HEX_EXPECT(out.find("DEADBEEF") != std::string::npos);
        HEX_EXPECT(out.find("cafebabe") != std::string::npos);
    }
}

void testParseHexClipboardTextFromDebuggerOutput()
{
    g_currentSuite = "parseHexClipboardTextFromDebuggerOutput";

    auto check = [&](const std::string &label, const std::string &input,
                     const std::vector<std::uint8_t> &expected) {
        std::vector<std::uint8_t> bytes;
        const bool ok = parseHexClipboardText(input, bytes);
        HEX_EXPECT(ok);
        if (bytes != expected) {
            std::fprintf(stderr, "FAIL [%s] %s: got %zu bytes, expected %zu\n",
                         g_currentSuite, label.c_str(), bytes.size(), expected.size());
            ++g_failures;
        } else {
            ++g_assertions;
        }
    };

    // lldb single-line memory dump.
    check("lldb",
          "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!....",
          {0x48,0x65,0x6c,0x6c,0x6f,0x20,0x77,0x6f,0x72,0x6c,0x64,0x21,0x0a,0x00,0x00,0x00});

    // gdb single line, per-byte 0x prefix.
    check("gdb",
          "0x7fff5fbff8c0: 0x48    0x65    0x6c    0x6c",
          {0x48,0x65,0x6c,0x6c});

    // xxd single line, concatenated nibbles.
    check("xxd",
          "00000000: 4865 6c6c 6f20 776f  Hello wo",
          {0x48,0x65,0x6c,0x6c,0x6f,0x20,0x77,0x6f});

    // x64dbg single line, pipe separator, ASCII gloss.
    check("x64dbg",
          "00007FF6BC471000 | 48 65 6C 6C 6F 20 57 6F  Hello Wo",
          {0x48,0x65,0x6C,0x6C,0x6F,0x20,0x57,0x6F});

    // C escape sequence — the user copies a string literal from source code.
    check("C escapes",
          "\\x48\\x65\\x6c\\x6c\\x6f",
          {0x48,0x65,0x6c,0x6c,0x6f});

    // C array literal with braces, commas, 0x prefixes.
    check("C array",
          "{ 0x48, 0x65, 0x6c, 0x6c, 0x6f }",
          {0x48,0x65,0x6c,0x6c,0x6f});

    // Multi-line lldb dump (16 bytes per line, three lines).
    check("multi-line lldb",
          "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!....\n"
          "0x100000010: 41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  ABCDEFGHIJKLMNOP\n",
          {0x48,0x65,0x6c,0x6c,0x6f,0x20,0x77,0x6f,0x72,0x6c,0x64,0x21,0x0a,0x00,0x00,0x00,
           0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x4b,0x4c,0x4d,0x4e,0x4f,0x50});

    // Negative: plain text must still fail the hex parse so the linear paste
    // path falls through to UTF-8 bytes.
    {
        std::vector<std::uint8_t> bytes;
        HEX_EXPECT(!parseHexClipboardText("Hello world", bytes));
    }
}

void testParseRectClipboardTextFromDebuggerOutput()
{
    g_currentSuite = "parseRectClipboardTextFromDebuggerOutput";

    // 2-line lldb dump → rect of 16 bytes wide × 2 rows tall.
    {
        const std::string in =
            "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!....\n"
            "0x100000010: 41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  ABCDEFGHIJKLMNOP\n";
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText(in, bytes, w, h));
        HEX_EXPECT_EQ(w, static_cast<std::size_t>(16));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(2));
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(32));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0x48));
        HEX_EXPECT_EQ(bytes[16], static_cast<std::uint8_t>(0x41));
        HEX_EXPECT_EQ(bytes[31], static_cast<std::uint8_t>(0x50));
    }

    // 3-line x64dbg dump → 8×3 rect.
    {
        const std::string in =
            "00007FF6BC471000 | 48 65 6C 6C 6F 20 57 6F  Hello Wo\n"
            "00007FF6BC471008 | 72 6C 64 21 00 00 00 00  rld!....\n"
            "00007FF6BC471010 | DE AD BE EF CA FE BA BE  ........\n";
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(parseRectClipboardText(in, bytes, w, h));
        HEX_EXPECT_EQ(w, static_cast<std::size_t>(8));
        HEX_EXPECT_EQ(h, static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0x48));
        HEX_EXPECT_EQ(bytes[8], static_cast<std::uint8_t>(0x72));
        HEX_EXPECT_EQ(bytes[16], static_cast<std::uint8_t>(0xDE));
        HEX_EXPECT_EQ(bytes[23], static_cast<std::uint8_t>(0xBE));
    }

    // Mismatched per-line byte counts → reject (unchanged behavior).
    {
        const std::string in =
            "0x100: 48 65 6c 6c\n"
            "0x110: 48 65\n";
        std::vector<std::uint8_t> bytes;
        std::size_t w = 0, h = 0;
        HEX_EXPECT(!parseRectClipboardText(in, bytes, w, h));
    }
}

void testDecodeRectPayloadRejectsAttacks()
{
    g_currentSuite = "decodeRectPayloadRejectsAttacks";

    // nullptr / undersized buffer → reject without dereference.
    {
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(nullptr, 0, p));
        HEX_EXPECT(!decodeRectPayload(nullptr, 100, p));
        const std::uint8_t tiny[10] = {};
        HEX_EXPECT(!decodeRectPayload(tiny, sizeof(tiny), p));
    }

    // Wrong magic → reject.
    {
        std::vector<std::uint8_t> payload(kRectPayloadHeaderSize, 0);
        payload[0] = 'X'; payload[1] = 'X'; payload[2] = 'X'; payload[3] = '1';
        payload[4] = 1;
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(payload.data(), payload.size(), p));
    }

    // Right magic, wrong version → reject.
    {
        auto payload = encodeRectPayload(RectClipboardKind::Bytes, 1, 1, nullptr, 0);
        payload[4] = 99;  // mutate version
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(payload.data(), payload.size(), p));
    }

    // Kind out of enum range → reject.
    {
        auto payload = encodeRectPayload(RectClipboardKind::Bytes, 1, 1, nullptr, 0);
        payload[5] = 99;  // mutate kind
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(payload.data(), payload.size(), p));
    }

    // dataLength larger than the actual buffer → reject (this is the key OOB check).
    // Forge a header that claims 1000 bytes of data while the actual buffer is only header-sized.
    {
        std::vector<std::uint8_t> payload(kRectPayloadHeaderSize, 0);
        std::memcpy(payload.data(), kRectPayloadMagic, sizeof(kRectPayloadMagic));
        payload[4] = kRectPayloadVersion;
        payload[5] = 0;  // kind=Bytes
        // dataLength = 1000 (LE32 at offset 16)
        payload[16] = 0xE8; payload[17] = 0x03; payload[18] = 0; payload[19] = 0;
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(payload.data(), payload.size(), p));
    }

    // dataLength == UINT32_MAX → reject (extreme overflow attempt).
    {
        std::vector<std::uint8_t> payload(kRectPayloadHeaderSize, 0);
        std::memcpy(payload.data(), kRectPayloadMagic, sizeof(kRectPayloadMagic));
        payload[4] = kRectPayloadVersion;
        payload[16] = 0xFF; payload[17] = 0xFF; payload[18] = 0xFF; payload[19] = 0xFF;
        RectPayload p;
        HEX_EXPECT(!decodeRectPayload(payload.data(), payload.size(), p));
    }
}

// =============================================================================
// readPreviewBuffer (SCI buffer-read abstraction)
// =============================================================================
//
// Why this exists: HexEditor.mm's readCurrentBuffer used to send 1,048,576
// SCI_GETCHARAT messages for a 1 MiB read (10+ s). The bulk SCI_GETTEXTRANGEFULL
// fix introduced a one-byte heap-buffer-overflow because Scintilla writes a
// trailing NUL at lpstrText[cpMax - cpMin] and the buffer was sized to exactly
// (cpMax - cpMin). The bug went undetected by the unit + smoke tiers (those
// don't talk to Scintilla) and only surfaced via flaky failures in the 22-min
// UI suite — by which point fixing it cost a full re-run.
//
// FakeScintilla obeys the SCI_GETTEXTRANGEFULL contract — including writing
// the NUL exactly where the real Scintilla does. The unit tests below allocate
// a destination, call readPreviewBuffer, and let ASan's heap-buffer-overflow
// detector catch any off-by-one in the buffer-shape code at <1 ms. Without
// the +1 in HexCore.cpp's readPreviewBuffer, ASan flags the NUL write and
// the test crashes with a clear stack trace.

class FakeScintilla : public hexedit::SciReader {
public:
    explicit FakeScintilla(std::vector<std::uint8_t> doc) : document_(std::move(doc)) {}

    std::size_t documentLength() const override { return document_.size(); }

    void readRange(std::size_t cpMin, std::size_t cpMax, char *dest) const override
    {
        // Match Scintilla docs: copy cpMax-cpMin bytes from doc, then write a
        // NUL at dest[cpMax-cpMin]. Caller must size for cpMax-cpMin+1.
        const std::size_t copyMax = (cpMin <= document_.size()) ? document_.size() - cpMin : 0;
        const std::size_t want = (cpMax > cpMin) ? cpMax - cpMin : 0;
        const std::size_t take = (want < copyMax) ? want : copyMax;
        if (take > 0) {
            std::memcpy(dest, document_.data() + cpMin, take);
        }
        dest[want] = '\0';   // The byte that overran into the next allocation pre-fix.
    }

private:
    std::vector<std::uint8_t> document_;
};

void testReadPreviewBuffer()
{
    g_currentSuite = "readPreviewBuffer";

    // Empty document — returns empty vector, totalLength = 0.
    {
        FakeScintilla fake({});
        std::size_t total = 999;
        auto bytes = hexedit::readPreviewBuffer(fake, 1024, &total);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(total, static_cast<std::size_t>(0));
    }

    // Document smaller than previewLimit — returns whole document.
    {
        FakeScintilla fake({0x41, 0x42, 0x43, 0x44, 0x45});
        std::size_t total = 0;
        auto bytes = hexedit::readPreviewBuffer(fake, 1024, &total);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(5));
        HEX_EXPECT_EQ(total, static_cast<std::size_t>(5));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0x41));
        HEX_EXPECT_EQ(bytes[4], static_cast<std::uint8_t>(0x45));
    }

    // Document exactly previewLimit — returns the full doc, no truncation flag.
    // This is the smallest size that exercises the +1 NUL-slot allocation: if
    // the buffer were sized to bytesToRead exactly, the NUL would write past
    // the end and ASan trips.
    {
        std::vector<std::uint8_t> doc(1024, 0xAA);
        FakeScintilla fake(doc);
        std::size_t total = 0;
        auto bytes = hexedit::readPreviewBuffer(fake, 1024, &total);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(1024));
        HEX_EXPECT_EQ(total, static_cast<std::size_t>(1024));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0xAA));
        HEX_EXPECT_EQ(bytes[1023], static_cast<std::uint8_t>(0xAA));
    }

    // Document one byte larger than previewLimit — returns previewLimit bytes,
    // total reflects the full size.
    {
        std::vector<std::uint8_t> doc(1025, 0xBB);
        FakeScintilla fake(doc);
        std::size_t total = 0;
        auto bytes = hexedit::readPreviewBuffer(fake, 1024, &total);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(1024));
        HEX_EXPECT_EQ(total, static_cast<std::size_t>(1025));
    }

    // Document much larger than previewLimit — exercises a realistic 1 MiB path.
    {
        std::vector<std::uint8_t> doc(2 * 1024 * 1024, 0xCC);
        // Sentinel-fill the first byte so we can verify we read from offset 0.
        doc[0] = 0xDE;
        doc[1] = 0xAD;
        FakeScintilla fake(doc);
        std::size_t total = 0;
        auto bytes = hexedit::readPreviewBuffer(fake, 1024 * 1024, &total);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(1024 * 1024));
        HEX_EXPECT_EQ(total, static_cast<std::size_t>(2 * 1024 * 1024));
        HEX_EXPECT_EQ(bytes[0], static_cast<std::uint8_t>(0xDE));
        HEX_EXPECT_EQ(bytes[1], static_cast<std::uint8_t>(0xAD));
        HEX_EXPECT_EQ(bytes[1024 * 1024 - 1], static_cast<std::uint8_t>(0xCC));
    }

    // outTotalLength == nullptr is allowed (caller doesn't always need it).
    {
        FakeScintilla fake({0x01, 0x02});
        auto bytes = hexedit::readPreviewBuffer(fake, 1024, nullptr);
        HEX_EXPECT_EQ(bytes.size(), static_cast<std::size_t>(2));
    }
}

void testSpanByteSource()
{
    g_currentSuite = "SpanByteSource";

    // Round-trip read of a full buffer.
    {
        const std::vector<std::uint8_t> src = {0x10, 0x20, 0x30, 0x40, 0x50};
        SpanByteSource source(src.data(), src.size());
        HEX_EXPECT_EQ(source.length(), src.size());

        std::uint8_t dest[8] = {};
        std::size_t got = source.read(0, dest, sizeof(dest));
        HEX_EXPECT_EQ(got, src.size());
        for (std::size_t i = 0; i < src.size(); ++i) {
            HEX_EXPECT_EQ(dest[i], src[i]);
        }
        // dest beyond src.size() is untouched (still 0).
        HEX_EXPECT_EQ(dest[src.size()], static_cast<std::uint8_t>(0));
    }

    // Partial read mid-buffer.
    {
        const std::vector<std::uint8_t> src = {0x10, 0x20, 0x30, 0x40, 0x50};
        SpanByteSource source(src.data(), src.size());
        std::uint8_t dest[3] = {};
        HEX_EXPECT_EQ(source.read(2, dest, 3), static_cast<std::size_t>(3));
        HEX_EXPECT_EQ(dest[0], static_cast<std::uint8_t>(0x30));
        HEX_EXPECT_EQ(dest[1], static_cast<std::uint8_t>(0x40));
        HEX_EXPECT_EQ(dest[2], static_cast<std::uint8_t>(0x50));
    }

    // Read clamped to remaining bytes when count > length - offset.
    {
        const std::vector<std::uint8_t> src = {0xAA, 0xBB, 0xCC};
        SpanByteSource source(src.data(), src.size());
        std::uint8_t dest[10] = {};
        HEX_EXPECT_EQ(source.read(1, dest, 10), static_cast<std::size_t>(2));
        HEX_EXPECT_EQ(dest[0], static_cast<std::uint8_t>(0xBB));
        HEX_EXPECT_EQ(dest[1], static_cast<std::uint8_t>(0xCC));
        // Bytes past the available range stay zero (not written by read()).
        HEX_EXPECT_EQ(dest[2], static_cast<std::uint8_t>(0x00));
    }

    // Reads past EOF return 0 without touching dest. ASan would catch a
    // bad-write here so this also doubles as an out-of-bounds guard test.
    {
        const std::vector<std::uint8_t> src = {0x01, 0x02};
        SpanByteSource source(src.data(), src.size());
        std::uint8_t dest[4] = {0xEE, 0xEE, 0xEE, 0xEE};
        HEX_EXPECT_EQ(source.read(2, dest, 4), static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(source.read(99, dest, 4), static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(dest[0], static_cast<std::uint8_t>(0xEE));
    }

    // Empty source — length() = 0, every read returns 0. nullptr data is OK
    // when length is 0; SpanByteSource never dereferences in that case.
    {
        SpanByteSource source(nullptr, 0);
        HEX_EXPECT_EQ(source.length(), static_cast<std::size_t>(0));
        std::uint8_t dest[1] = {};
        HEX_EXPECT_EQ(source.read(0, dest, 1), static_cast<std::size_t>(0));
    }

    // count = 0 short-circuits regardless of offset.
    {
        const std::vector<std::uint8_t> src = {0x42};
        SpanByteSource source(src.data(), src.size());
        std::uint8_t dest[1] = {};
        HEX_EXPECT_EQ(source.read(0, dest, 0), static_cast<std::size_t>(0));
        HEX_EXPECT_EQ(dest[0], static_cast<std::uint8_t>(0));
    }
}

}

int main()
{
    testHexDigitValue();
    testIsVisibleEditableOffset();
    testClampCursor();
    testMoveCursor();
    testLineNavigation();
    testDocumentNavigation();
    testNavigateLeftRight();
    testSelectedOrCurrentRange();
    testPlanHexDigitEdit();
    testPlanAsciiByteEdit();
    testPlanDeleteEdit();
    testPlanPasteEdit();
    testFormatHexClipboardText();
    testParseHexClipboardText();
    testViewModeShape();
    testFormatCell();
    testDisplayPositionMapping();
    testResolveGotoOffset();
    testParseSearchPattern();
    testFindBytePattern();
    testClampCursorMode();
    testPlanBitEdit();
    testNavigateInDisplayOrder();
    testComputeByteDiffs();
    testMakeRectSelection();
    testRectToRanges();
    testExtractRectBytes();
    testFormatRectClipboardHex();
    testParseRectClipboardText();
    testRectPayloadCodecRoundTrip();
    testDecodeRectPayloadRejectsAttacks();
    testStripHexDumpAddressAndAscii();
    testParseHexClipboardTextFromDebuggerOutput();
    testParseRectClipboardTextFromDebuggerOutput();
    testReadPreviewBuffer();
    testSpanByteSource();

    if (g_failures == 0) {
        std::printf("PASS: %d assertions across 36 suites\n", g_assertions);
        return 0;
    }
    std::printf("FAIL: %d/%d assertions failed\n", g_failures, g_assertions);
    return 1;
}
