// libFuzzer harness for hexedit::makeRectSelection.
//
// Lower attack-surface value than the parsers — makeRectSelection's inputs
// are integers the plugin computes itself (cursor offset, anchor offset,
// row width, document length), not attacker-controlled bytes. But the
// integer math (modulo divisions, min/max comparisons, and the implicit
// width/height arithmetic) is exactly the kind of place a UB hides for years.
// Including it in the fuzz suite is cheap insurance.
//
// Layout of the input bytes (little-endian, defensive defaults on truncation):
//   [0..7]   anchorOffset (uint64)
//   [8..15]  endOffset    (uint64)
//   [16..23] bytesPerRow  (uint64)
//   [24..31] totalLength  (uint64)

#include "HexCore.h"

#include <cstddef>
#include <cstdint>

namespace {
constexpr std::size_t kHeaderSize = 32;

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
    const std::size_t anchor      = static_cast<std::size_t>(readLE64(data + 0));
    const std::size_t end         = static_cast<std::size_t>(readLE64(data + 8));
    const std::size_t bytesPerRow = static_cast<std::size_t>(readLE64(data + 16));
    const std::size_t totalLength = static_cast<std::size_t>(readLE64(data + 24));

    hexedit::RectSelection rect = hexedit::makeRectSelection(anchor, end, bytesPerRow, totalLength);

    // Touch the result so the optimiser can't elide the call entirely.
    if (rect.active()) {
        const std::size_t bytes = rect.totalBytes();
        (void)bytes;
        const auto ranges = hexedit::rectToRanges(rect, totalLength);
        (void)ranges.size();
    }
    return 0;
}
