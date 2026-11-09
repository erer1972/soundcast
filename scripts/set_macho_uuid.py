#!/usr/bin/env python3
"""Overwrite the LC_UUID of a thin Mach-O executable with a fixed value.

macOS Local Network privacy remembers an app's permission by its main
executable's Mach-O UUID, which the linker regenerates on every code
change. Pinning it keeps the user's grant across rebuilds. Run before
codesigning (the signature covers the UUID bytes).

Usage: set_macho_uuid.py <executable> <uuid>
"""
import struct
import sys
import uuid

MH_MAGIC_64 = 0xFEEDFACF
LC_UUID = 0x1B


def main() -> int:
    path, value = sys.argv[1], uuid.UUID(sys.argv[2])
    with open(path, "r+b") as f:
        data = bytearray(f.read())
        magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
        if magic != MH_MAGIC_64:
            print(f"{path}: not a thin 64-bit Mach-O (magic {magic:#x})", file=sys.stderr)
            return 1
        offset = 32  # sizeof(mach_header_64)
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmd == LC_UUID:
                data[offset + 8:offset + 24] = value.bytes
                f.seek(0)
                f.write(data)
                print(f"{path}: LC_UUID set to {value}")
                return 0
            offset += cmdsize
    print(f"{path}: no LC_UUID load command", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
