#!/usr/bin/env python3
"""Report the function count and the largest function body of a wasm module.

Stylus refuses to activate a module whose single function body carries more opcodes than a
fixed limit. Counting opcodes exactly needs a full instruction decoder; the body's encoded
size does not, and tracks it closely, since every instruction occupies at least one byte —
one rejected build decoded to 0.82 opcodes per byte.

This is a proxy, not a proof: the ratio is data-dependent (dense single-byte arithmetic
approaches 1.0, constant-heavy code stays near 0.2), and the on-chain counter reads the module
as submitted rather than this file. Treat the check as an early warning that keeps the budget
visible in ordinary CI. The authoritative test is `cargo stylus check` against a live RPC.

Prints "<function count> <largest body size in bytes>".
"""

import sys


def read_uleb(data, i):
    """Decode an unsigned LEB128 at `i`; return (value, index after it)."""
    result = 0
    shift = 0
    while True:
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, i
        shift += 7


def code_section(data):
    """Return the (start, length) of the code section, or None when there is none."""
    if data[:4] != b"\0asm":
        raise ValueError("not a wasm module")
    i = 8  # magic + version
    while i < len(data):
        section_id = data[i]
        i += 1
        size, i = read_uleb(data, i)
        if section_id == 10:
            return i, size
        i += size
    return None


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <module.wasm>", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as handle:
        data = handle.read()

    section = code_section(data)
    if section is None:
        print("0 0")
        return 0

    i, _size = section
    count, i = read_uleb(data, i)
    largest = 0
    for _ in range(count):
        body_size, i = read_uleb(data, i)
        largest = max(largest, body_size)
        i += body_size

    print(f"{count} {largest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
