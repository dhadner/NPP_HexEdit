// libFuzzer harness for hexedit::stripHexDumpAddressAndAscii.
//
// Attack surface: any clipboard text from any app on the system. When the user
// pastes into the hex view, every line is run through stripHexDumpAddressAndAscii
// before tokenisation to remove address columns and ASCII gloss from the output
// of lldb (`memory read`), gdb (`x/16xb`), xxd, x64dbg, IDA, C-string escape
// sequences, and C array literals. The heuristic walks indices, looks for
// separators, and rewrites characters in place — exactly the kind of code where
// a malformed input could read past the end of the string or trigger UB.
//
// This is the broadest external-input boundary the plugin exposes: it accepts
// arbitrary text and applies multi-format pattern matching. ASan/UBSan catch
// any OOB read or signed overflow during the rewrite; libFuzzer catches hangs.
//
// Build via the project's ENABLE_FUZZ_TESTS=ON flag (requires Homebrew LLVM).
// Run: ctest -L fuzz, or for a longer soak:
//   ./fuzz_stripHexDumpAddressAndAscii -max_total_time=300 corpus/

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    std::string line(reinterpret_cast<const char *>(data), size);
    (void)hexedit::stripHexDumpAddressAndAscii(line);
    return 0;
}
