# HexCore fuzz harnesses

Four libFuzzer harnesses against the C++ parsers in `macos/src/core/HexCore.{h,cpp}`. Each is a single TU that exposes `LLVMFuzzerTestOneInput` and gets linked with `-fsanitize=fuzzer,address,undefined` so any OOB read, UB, or hang surfaces as a crash with a saved repro.

| Harness | Function under test | Attack surface |
|---|---|---|
| `fuzz_parseRectClipboardText` | `parseRectClipboardText` | Anything on the system pasteboard's text type — pasted with a rect destination selection active |
| `fuzz_decodeRectPayload` | `decodeRectPayload` | The custom-UTI binary payload `org.notepad-plus-plus.HexEditor.rectangular`. Highest-risk parser — any process on the user's Mac can set this. |
| `fuzz_extractRectBytes` | `extractRectBytes` | Document buffer indexed by an attacker-influenced RectSelection — protects against bad shape sneaking past `makeRectSelection` / `decodeRectPayload` |
| `fuzz_makeRectSelection` | `makeRectSelection` (+ `rectToRanges`) | Integer math against attacker-influenced offsets / widths |

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

A short ctest run (`ctest -L fuzz`) finishing in ~2 minutes total with no crashes is a clean pass. libFuzzer prints a final-stats line per harness:

```text
#1234567 NEW    cov: 412 ft: 891 corp: 47/2048b lim: 4096 exec/s: 39000 ...
```

A regression shows as a saved `crash-<hash>` artifact in the working directory plus the libFuzzer stack trace + ASan/UBSan diagnostic. Re-run with the artifact path as an argument to reproduce:

```sh
./fuzz_decodeRectPayload crash-7a8f...
```
