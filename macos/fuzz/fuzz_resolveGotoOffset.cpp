// libFuzzer harness for hexedit::resolveGotoOffset.
//
// Attack surface: the Goto Offset dialog text field (Cmd+L). Accepts decimal,
// 0x-prefixed hex, and relative `+` / `-` offsets resolved against the current
// cursor and document length. The parser does signed/unsigned arithmetic with
// SIZE_MAX-adjacent values; malformed or wrap-around-inducing input could trip
// UB in the offset math.
//
// We pull currentOffset and totalLength from the fuzzer-supplied bytes so the
// harness exercises the relative-offset arithmetic across the full size_t
// range (clamped to a 16 GB sentinel so libFuzzer doesn't waste time on
// pathological multi-petabyte inputs).
//
// Build via the project's ENABLE_FUZZ_TESTS=ON flag (requires Homebrew LLVM).
// Run: ctest -L fuzz, or for a longer soak:
//   ./fuzz_resolveGotoOffset -max_total_time=300 corpus/

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <string>

namespace {
constexpr std::size_t kHeaderSize = 16;

std::uint64_t readLE64(const std::uint8_t *p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v |= static_cast<std::uint64_t>(p[i]) << (8 * i);
    }
    return v;
}
}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    if (size < kHeaderSize) {
        return 0;
    }
    // Cap inputs at 16 GB so the harness explores realistic offsets rather than
    // wrapping multi-petabyte uint64 values that would never appear in practice.
    constexpr std::uint64_t kCap = 1ULL << 34;  // 16 GB
    const std::size_t currentOffset = static_cast<std::size_t>(readLE64(data + 0) % kCap);
    const std::size_t totalLength   = static_cast<std::size_t>(readLE64(data + 8) % kCap);

    std::string text(reinterpret_cast<const char *>(data + kHeaderSize), size - kHeaderSize);
    std::size_t outOffset = 0;
    (void)hexedit::resolveGotoOffset(text, currentOffset, totalLength, outOffset);
    return 0;
}
