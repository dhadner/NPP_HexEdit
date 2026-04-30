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

void testMakeHexDump()
{
    g_currentSuite = "makeHexDump";

    HEX_EXPECT_EQ(makeHexDump({}, 0), std::string("The current document is empty."));

    std::vector<std::uint8_t> three = { 'A', 'B', 'C' };
    std::string dump = makeHexDump(three, 3);
    HEX_EXPECT(dump.find("00000000  41 42 43") != std::string::npos);
    HEX_EXPECT(dump.find("|ABC") != std::string::npos);
    HEX_EXPECT(dump.find("Preview truncated") == std::string::npos);

    std::vector<std::uint8_t> sixteen(16, 0x55);
    dump = makeHexDump(sixteen, 16);
    HEX_EXPECT(dump.find("00000000  55 55 55 55 55 55 55 55  55 55 55 55 55 55 55 55") != std::string::npos);

    std::vector<std::uint8_t> truncated(8, 0xAA);
    dump = makeHexDump(truncated, 1024);
    HEX_EXPECT(dump.find("Preview truncated at 8 of 1024 bytes.") != std::string::npos);

    std::vector<std::uint8_t> nonPrintable = { 0x00, 0x1F, 0x7F, 0x80, 'a' };
    dump = makeHexDump(nonPrintable, 5);
    HEX_EXPECT(dump.find("|....a") != std::string::npos);
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
    testMakeHexDump();

    if (g_failures == 0) {
        std::printf("PASS: %d assertions across 13 suites\n", g_assertions);
        return 0;
    }
    std::printf("FAIL: %d/%d assertions failed\n", g_failures, g_assertions);
    return 1;
}
