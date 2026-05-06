// libFuzzer harness for hexedit::parseHexClipboardText (linear paste path).
//
// Attack surface: anything on the system pasteboard's text type that the user
// pastes while a linear caret/selection is active. Distinct from the rect
// harness (fuzz_parseRectClipboardText): the linear path uses the same
// tokeniser but different exit conditions (no width/height to enforce; any
// number of bytes is accepted). Linear paste is by far the more common
// clipboard route, so it deserves its own coverage even though much of the
// inner code is shared.
//
// Build via the project's ENABLE_FUZZ_TESTS=ON flag (requires Homebrew LLVM).
// Run: ctest -L fuzz, or for a longer soak:
//   ./fuzz_parseHexClipboardText -max_total_time=300 corpus/

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    std::string text(reinterpret_cast<const char *>(data), size);
    std::vector<std::uint8_t> out;
    (void)hexedit::parseHexClipboardText(text, out);
    return 0;
}
