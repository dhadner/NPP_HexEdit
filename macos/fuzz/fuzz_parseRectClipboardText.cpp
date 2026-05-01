// libFuzzer harness for hexedit::parseRectClipboardText.
//
// Attack surface: anything on the system pasteboard's text type (e.g.
// `public.utf8-plain-text`) that the user pastes while a rectangular
// destination selection is active. Per the chunk-3 design (Q2.b), the parser
// accepts hex tokens with mixed separators OR raw ASCII bytes, so the input
// space is broad — and therefore worth fuzzing for memory safety + termination.
//
// Build via the project's ENABLE_FUZZ_TESTS=ON flag (requires Homebrew LLVM).
// Run: ctest -L fuzz, or for a longer soak:
//   ./fuzz_parseRectClipboardText -max_total_time=300 corpus/

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    std::string text(reinterpret_cast<const char *>(data), size);
    std::vector<std::uint8_t> bytes;
    std::size_t width = 0;
    std::size_t height = 0;
    (void)hexedit::parseRectClipboardText(text, bytes, width, height);
    // ASan/UBSan catch any OOB read or signed overflow during parse; libFuzzer
    // catches hangs / OOMs / crashes. Successful return is a reachability + no-bug
    // signal, not correctness — correctness lives in the unit-test suite.
    return 0;
}
