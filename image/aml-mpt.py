#!/usr/bin/env python3
"""Print a partition's start sector and sector count from an Amlogic eMMC partition table.

  aml-mpt.py <mpt.bin> <name>

The MPT format is in aml-layout.py.
"""
import struct
import sys

SECTOR = 512
ENTRY = 40


def partitions(path: str) -> dict[str, tuple[int, int]]:
    raw = open(path, "rb").read()
    if raw[:4] != b"MPT\0":
        sys.exit(f"{path}: not an Amlogic MPT")
    count = struct.unpack("<I", raw[16:20])[0]
    table = {}
    for i in range(count):
        e = raw[24 + i * ENTRY : 24 + (i + 1) * ENTRY]
        name = e[:16].split(b"\0")[0].decode()
        size, offset = struct.unpack("<QQ", e[16:32])
        table[name] = (offset // SECTOR, size // SECTOR)
    return table


def main() -> None:
    path, name = sys.argv[1:]
    table = partitions(path)
    if name not in table:
        sys.exit(f"{path}: no partition named {name}")
    start, count = table[name]
    print(start, count)


if __name__ == "__main__":
    main()
