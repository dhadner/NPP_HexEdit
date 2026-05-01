// libFuzzer harness for hexedit::decodeRectPayload.
//
// Attack surface: the custom-UTI binary payload
// `org.notepad-plus-plus.HexEditor.rectangular` that any process on the user's
// Mac can set on the system pasteboard. A single Cmd+V in the hex view pipes
// these bytes through decodeRectPayload — making this the highest-risk parser
// in the plugin from a security standpoint.
//
// Notable scenarios libFuzzer should burn through:
//   - Truncated header (length < kRectPayloadHeaderSize).
//   - Bad magic / wrong version / kind out of enum range.
//   - Forged dataLength larger than the actual buffer (the OOB-read attack).
//   - Width / height with values that overflow when multiplied by callers.
//
// Build via ENABLE_FUZZ_TESTS=ON (requires Homebrew LLVM).

#include "HexCore.h"

#include <cstddef>
#include <cstdint>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    hexedit::RectPayload payload;
    if (!hexedit::decodeRectPayload(data, size, payload)) {
        return 0;
    }
    // Decode succeeded — touch the parsed range to make ASan complain if the
    // dataLength bound check missed a byte. This mimics what
    // applyRectBytesPaste does with the payload immediately after decode.
    if (payload.data != nullptr) {
        volatile std::uint8_t sink = 0;
        for (std::uint32_t i = 0; i < payload.dataLength; ++i) {
            sink = static_cast<std::uint8_t>(sink ^ payload.data[i]);
        }
        (void)sink;
    }
    return 0;
}
