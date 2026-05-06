#!/usr/bin/env python3
"""Generate a deterministic test fixture file for the hex-editor UI tests.

Each byte at offset N has value 0x20 + (N mod 95) — i.e. cycles through
the 95 printable ASCII characters from space (0x20) to tilde (0x7E).
The fixture is therefore valid UTF-8 and contains no `\n`, `\r`, or
high-bit bytes, so Notepad++ macOS doesn't re-encode the file when it
loads (which it does for any byte above 0x7F, inflating the buffer by
~50%) and doesn't normalise line endings (which would change the byte
count). This means the file's on-disk size matches the in-buffer size
that the hex-view status bar reports.

Trivially verifiable from a test: read offset N, expect 0x20 + N % 95.
For example offset 0 = 0x20 (' '), offset 94 = 0x7E ('~'), offset 95
wraps to 0x20 (' ') again. The four-byte sequence "ABCD" (0x41 0x42
0x43 0x44) appears every 95 bytes starting at offset 33.

Idempotent: regenerating with the same size argument produces a
byte-identical file. Used by macos/ui-tests-xcode/run-tests.sh to
manufacture the 100 MB fixture (too large for git) at first run, and
can be re-run to refresh the smaller checked-in fixtures if their
sizes ever change.

Usage:
    generate-test-fixture.py <output-path> <size-in-bytes>

Examples:
    generate-test-fixture.py /tmp/100k.bin 100000
    generate-test-fixture.py /tmp/100MB.bin $((100 * 1024 * 1024))
"""
from __future__ import annotations

import os
import sys


def write_pattern(path: str, size: int) -> None:
    """Write `size` bytes of the cycling 0x20..0x7E (printable ASCII) pattern."""
    chunk = bytes(range(0x20, 0x7F))  # 95 chars: space through tilde
    period = len(chunk)
    with open(path, "wb") as f:
        written = 0
        while written < size:
            remaining = size - written
            if remaining >= period:
                f.write(chunk)
                written += period
            else:
                f.write(chunk[:remaining])
                written += remaining


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} <output-path> <size-bytes>\n")
        return 2
    path = argv[1]
    try:
        size = int(argv[2])
    except ValueError:
        sys.stderr.write(f"error: size must be an integer, got {argv[2]!r}\n")
        return 2
    if size < 0:
        sys.stderr.write(f"error: size must be non-negative, got {size}\n")
        return 2

    # Idempotent skip: if the file already exists with the right size, leave it.
    # Avoids re-writing the 100 MB fixture on every CMake reconfigure.
    if os.path.isfile(path) and os.path.getsize(path) == size:
        return 0

    # Make sure the parent directory exists.
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    write_pattern(path, size)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
