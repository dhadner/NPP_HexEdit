// libFuzzer harness for hexedit::parseSearchPattern.
//
// Attack surface: the Find / Find-and-Replace dialog text fields. Every search
// invocation parses the user's input — auto-detecting hex (via 0x/0X prefix or
// hex digits with separators) vs. raw ASCII bytes. The heuristic walks the
// string, classifies characters, and reconstructs a byte sequence; malformed
// or pathological inputs (e.g. mixed hex separators, unclosed escapes,
// adversarial Unicode) could trip the parser into UB.
//
// We toggle matchCase using a single byte from the input so both code paths
// are exercised within one harness; the remaining bytes form the search text.
//
// Build via the project's ENABLE_FUZZ_TESTS=ON flag (requires Homebrew LLVM).
// Run: ctest -L fuzz, or for a longer soak:
//   ./fuzz_parseSearchPattern -max_total_time=300 corpus/

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    bool matchCase = false;
    if (size > 0) {
        matchCase = (data[0] & 0x01) != 0;
        ++data;
        --size;
    }
    std::string text(reinterpret_cast<const char *>(data), size);
    hexedit::SearchPattern pattern;
    (void)hexedit::parseSearchPattern(text, matchCase, pattern);
    return 0;
}
