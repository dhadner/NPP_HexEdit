# HexCore fuzz harnesses

Eight libFuzzer harnesses against the C++ parsers in `macos/src/core/HexCore.{h,cpp}` — every external-input boundary the plugin exposes. Each is a single TU that exposes `LLVMFuzzerTestOneInput` and gets linked with `-fsanitize=fuzzer,address,undefined` so any OOB read, UB, or hang surfaces as a crash with a saved repro.

**Rectangular-clipboard path** (custom-UTI binary + text fallback):

| Harness | Function under test | Attack surface |
|---|---|---|
| `fuzz_parseRectClipboardText` | `parseRectClipboardText` | Pasteboard text type — pasted with a rect destination selection active |
| `fuzz_decodeRectPayload` | `decodeRectPayload` | The custom-UTI binary payload `org.notepad-plus-plus.HexEditor.rectangular`. Any process on the user's Mac can set this. |
| `fuzz_extractRectBytes` | `extractRectBytes` | Document buffer indexed by an attacker-influenced RectSelection — protects against bad shape sneaking past `makeRectSelection` / `decodeRectPayload` |
| `fuzz_makeRectSelection` | `makeRectSelection` (+ `rectToRanges`) | Integer math against attacker-influenced offsets / widths |

**General external-input surface** (added 2026-05-06):

| Harness | Function under test | Attack surface |
|---|---|---|
| `fuzz_stripHexDumpAddressAndAscii` | `stripHexDumpAddressAndAscii` | The broadest surface — every line of every external-app paste runs through this multi-format cleaner (lldb / gdb / xxd / x64dbg / IDA / C-escape / C-array). |
| `fuzz_parseSearchPattern` | `parseSearchPattern` | Find / Find-and-Replace dialog input. Auto-detects ASCII vs hex on every keystroke. |
| `fuzz_parseHexClipboardText` | `parseHexClipboardText` | Linear hex-clipboard paste path (the rect harness covers the rect-shape variant; this covers the more common linear case). |
| `fuzz_resolveGotoOffset` | `resolveGotoOffset` | Goto Offset dialog (Cmd+L). Decimal / `0x` hex / relative `+`/`-` offsets resolved against current cursor + document length — exercises wrap-around arithmetic at SIZE_MAX edges. |

## Setup (one-time)

libFuzzer's runtime archive isn't shipped with Apple Clang. Install Homebrew LLVM:

```sh
brew install llvm
```

The CMake configure step checks for `/opt/homebrew/opt/llvm/bin/clang++` and errors out clearly if missing.

## Build

Use a separate build directory so the regular Release universal build is unaffected:

```sh
cmake -S macos -B macos/build-fuzz \
  -DENABLE_FUZZ_TESTS=ON \
  -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++ \
  -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang
cmake --build macos/build-fuzz
```

`ENABLE_FUZZ_TESTS=ON` implies `ENABLE_SANITIZERS=ON` (ASan + UBSan), and forces `arm64`-only because libFuzzer can't run a universal binary.

## Run

Default: each harness runs for `FUZZ_DURATION_SEC` seconds (30s; configurable via `-DFUZZ_DURATION_SEC=N`):

```sh
ctest --test-dir macos/build-fuzz -L fuzz --output-on-failure
```

For a longer soak against one harness:

```sh
./macos/build-fuzz/fuzz_decodeRectPayload \
    -max_total_time=600 \
    -print_final_stats=1 \
    corpus/  # optional input corpus
```

To save crashing repros to disk:

```sh
./macos/build-fuzz/fuzz_decodeRectPayload \
    -artifact_prefix=/tmp/hexedit-fuzz/ \
    -max_total_time=600
```

## Adding a new harness

1. Drop `fuzz_<name>.cpp` in this directory exposing `extern "C" int LLVMFuzzerTestOneInput(const uint8_t *, size_t)`.
2. Add the basename to `HEX_FUZZ_HARNESSES` in [macos/CMakeLists.txt](../CMakeLists.txt).
3. Reconfigure + build. Each new harness automatically gets a CTest entry under the `fuzz` label.

## What success looks like

A short ctest run (`ctest -L fuzz`) finishing in ~4 minutes total (8 harnesses × 30 s) with no crashes is a clean pass. libFuzzer prints a final-stats line per harness:

```text
#1234567 NEW    cov: 412 ft: 891 corp: 47/2048b lim: 4096 exec/s: 39000 ...
```

A regression shows as a saved `crash-<hash>` artifact in the working directory plus the libFuzzer stack trace + ASan/UBSan diagnostic. Re-run with the artifact path as an argument to reproduce:

```sh
./fuzz_decodeRectPayload crash-7a8f...
```
