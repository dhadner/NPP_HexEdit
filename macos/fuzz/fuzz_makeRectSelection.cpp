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
    // Clamp inputs to ranges the plugin ever realistically passes. In production:
    //   * previewTotalLength is bounded by PREVIEW_LIMIT (1 MB)
    //   * bytesPerRow is bounded by HEX_MAX_BYTES_PER_ROW (128) and never zero
    //     at call time (caller asserts), so 1..128 is the production envelope
    //   * anchor / end are clamped to totalLength inside makeRectSelection
    // Without these clamps, the fuzzer hands in SIZE_MAX values that produce
    // a rect with rect.height in the petabytes — the resulting reserve in
    // rectToRanges trips ASan with allocation-size-too-big, but no production
    // call path can reach those values. We're fuzzing for memory-safety bugs
    // in the parser, not exercising allocator pressure with unrealistic input.
    constexpr std::size_t kMaxTotalLength = 1ULL << 20;     // 1 MB, matches PREVIEW_LIMIT
    constexpr std::size_t kMaxBytesPerRow = 128;
    const std::size_t totalLength = static_cast<std::size_t>(readLE64(data + 24)) % (kMaxTotalLength + 1);
    const std::size_t bytesPerRow =
        (static_cast<std::size_t>(readLE64(data + 16)) % kMaxBytesPerRow) + 1;
    const std::size_t anchor = static_cast<std::size_t>(readLE64(data + 0));
    const std::size_t end    = static_cast<std::size_t>(readLE64(data + 8));

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
