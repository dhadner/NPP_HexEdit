// libFuzzer harness for hexedit::extractRectBytes.
//
// extractRectBytes reads the document buffer indexed by a RectSelection's
// (originOffset, width, height, bytesPerRow) tuple. The rectangle is normally
// constructed by makeRectSelection or unmarshalled from a custom-UTI paste —
// either could feed in a malformed shape if some upstream invariant breaks.
// This fuzzer constructs both halves from libFuzzer-supplied bytes so any
// OOB read in the per-row memcpy gets caught by ASan.
//
// Layout of the input bytes (little-endian, defensive defaults on truncation):
//   [0..7]   originOffset  (uint64)
//   [8..15]  width         (uint64)
//   [16..23] height        (uint64)
//   [24..31] bytesPerRow   (uint64)
//   [32..39] totalLength   (uint64; clipped to remaining input length)
//   [40..]   buffer bytes  (whatever remains)

#include "HexCore.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {
constexpr std::size_t kHeaderSize = 40;

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
    hexedit::RectSelection rect;
    rect.originOffset = static_cast<std::size_t>(readLE64(data + 0));
    rect.width        = static_cast<std::size_t>(readLE64(data + 8));
    rect.height       = static_cast<std::size_t>(readLE64(data + 16));
    rect.bytesPerRow  = static_cast<std::size_t>(readLE64(data + 24));

    // Clamp shape to something sane — fuzzer-supplied uint64 values would
    // otherwise tip the test into multi-GB allocations and time out, which
    // libFuzzer would (correctly) flag as a hang. The interesting bugs are
    // OOB-read at modest sizes, not OOM at unrealistic ones; cap at 64 KB.
    rect.width       = rect.width       % 256;
    rect.height      = rect.height      % 256;
    rect.bytesPerRow = (rect.bytesPerRow % 256) + 1;
    rect.originOffset = rect.originOffset % (1ULL << 16);

    const std::size_t bufferLen = size - kHeaderSize;
    const std::size_t totalLength = static_cast<std::size_t>(readLE64(data + 32)) % (bufferLen + 1);
    const std::uint8_t *buffer = data + kHeaderSize;

    std::vector<std::uint8_t> out;
    (void)hexedit::extractRectBytes(buffer, totalLength, rect, out);
    return 0;
}
