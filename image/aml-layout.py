#!/usr/bin/env python3
"""Rewrite an Amlogic board's eMMC partition table and device trees for single boot.

  aml-layout.py <factory-mpt.bin> <factory-multidtb.bin> <emmc-sectors> <out-mpt.bin> <out-dtb.bin>

Single boot, as ampart's `dclone data::-1:4` leaves it: bootloader, reserved, cache at 0 bytes, env,
and one data partition to the end - Android's partitions gone. The vendor U-Boot lays the eMMC out
from the device tree's /partitions node at every eMMC init and keeps the result in the MPT; both
are rewritten here, so the two agree from the first boot.

  MPT   the partition table opening reserved: "MPT", version, count at 16, checksum at 20, then
        40-byte entries of name, size, offset, mask. bootloader sits at 0 and reserved at 36 MiB;
        every later partition starts 8 MiB past the previous end, and data takes the rest. The
        checksum is Amlogic's: the first entry's ten words, summed, times the count.
  DTB   one 256 KiB slot, written twice from reserved +4 MiB: the gzipped multi-DTB, then magic,
        version, timestamp and a checksum - the sum of every word but the last. In /partitions,
        `parts` drops to 1, `part-0` names data and the other part-N become FDT_NOPs, so every
        size and offset stays. Without cache listed, U-Boot takes its own: 0 bytes, mask 0.
        cache's node is zeroed too, for anything reading it by name.
"""
import gzip
import struct
import sys

MIB = 1 << 20
SECTOR = 512
GAP = 8 * MIB
RESERVED_OFFSET = 36 * MIB
ENTRY = 40
SLOT = 256 * 1024
DTB_MAGIC = 0x00447E41
KEPT = (b"bootloader", b"reserved", b"cache", b"env", b"data")
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def compose(factory: bytes, entries: list[bytes], emmc_bytes: int) -> bytes:
    """An MPT of these entries, their offsets laid out as the vendor U-Boot lays them."""
    body, end = b"", 0
    for e in entries:
        name = e[:16].split(b"\0")[0]
        size, _ = struct.unpack("<QQ", e[16:32])
        if name == b"bootloader":
            offset = 0
        elif name == b"reserved":
            offset = RESERVED_OFFSET
        else:
            offset = end + GAP
        if name == b"data":
            size = emmc_bytes - offset
        body += e[:16] + struct.pack("<QQ", size, offset) + e[32:ENTRY]
        end = offset + size
    checksum = sum(struct.unpack("<10I", body[:ENTRY])) * len(entries) & 0xFFFFFFFF
    table = factory[:16] + struct.pack("<II", len(entries), checksum) + body
    return table.ljust(len(factory), b"\0")


def mpt(factory: bytes, emmc_bytes: int) -> bytes:
    if factory[:4] != b"MPT\0" or factory[4:12] != b"01.00.00":
        sys.exit("not a version 01.00.00 MPT; this layout knows only that one")
    count = struct.unpack("<I", factory[16:20])[0]
    entries = [factory[24 + i * ENTRY : 24 + (i + 1) * ENTRY] for i in range(count)]
    # the rules must reproduce this board's own table before they are trusted to write a new one
    if compose(factory, entries, emmc_bytes) != factory:
        sys.exit("the factory MPT is not laid out by these rules - a different U-Boot, or a wrong eMMC size")
    by_name = {e[:16].split(b"\0")[0]: e for e in entries}
    kept = []
    for name in KEPT:
        e = by_name[name]
        if name == b"cache":
            e = e[:16] + struct.pack("<QQI", 0, 0, 0) + e[36:ENTRY]
        kept.append(e)
    return compose(factory, kept, emmc_bytes)


def props(fdt: bytes, base: int) -> dict[tuple[str, ...], tuple[int, int]]:
    """Every property in the tree at base, by path: (value offset, length)."""
    struct_off, strings_off = struct.unpack(">II", fdt[base + 8 : base + 16])
    p, path, found = base + struct_off, [], {}
    while True:
        token = struct.unpack(">I", fdt[p : p + 4])[0]
        p += 4
        if token == FDT_BEGIN_NODE:
            end = fdt.index(b"\0", p)
            path.append(fdt[p:end].decode())
            p = (end + 4) & ~3
        elif token == FDT_END_NODE:
            path.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack(">II", fdt[p : p + 8])
            s = base + strings_off + nameoff
            name = fdt[s : fdt.index(b"\0", s)].decode()
            found[tuple(path[1:]) + (name,)] = (p + 8, length)
            p = (p + 8 + length + 3) & ~3
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            return found
        else:
            sys.exit(f"bad FDT token {token} at {p - 4}")


def single_boot(container: bytearray, base: int) -> None:
    found = props(container, base)

    def cell(*path: str) -> tuple[int, int]:
        if path not in found:
            sys.exit(f"DTB at {base}: no {'/'.join(path)}")
        return found[path]

    data_phandle = container[slice(*(lambda o, n: (o, o + n))(*cell("partitions", "data", "phandle")))]
    for path, value in ((("partitions", "parts"), struct.pack(">I", 1)),
                        (("partitions", "part-0"), bytes(data_phandle)),
                        (("partitions", "cache", "size"), bytes(8))):
        off, length = cell(*path)
        if length != len(value):
            sys.exit(f"DTB at {base}: {'/'.join(path)} is {length} bytes, not {len(value)}")
        container[off : off + length] = value
    # a property is its token, length and name offset, then the padded value
    for key, (off, length) in found.items():
        if key[:1] == ("partitions",) and key[1].startswith("part-") and key[1] != "part-0":
            start, words = off - 12, (12 + ((length + 3) & ~3)) // 4
            container[start : start + words * 4] = struct.pack(f">{words}I", *[FDT_NOP] * words)


def dtb_slot(multidtb: bytes) -> bytes:
    container = bytearray(multidtb)
    if container[:4] != b"AML_":
        sys.exit("not an AML_ multi-DTB")
    count = struct.unpack("<I", container[8:12])[0]
    for i in range(count):
        single_boot(container, struct.unpack("<I", container[12 + i * 56 + 48 : 12 + i * 56 + 52])[0])
    data = gzip.compress(bytes(container), mtime=0)
    if len(data) > SLOT - 16:
        sys.exit(f"the gzipped multi-DTB is {len(data)} bytes, past the {SLOT - 16}-byte slot")
    slot = data.ljust(SLOT - 16, b"\0") + struct.pack("<III", DTB_MAGIC, 1, 1)
    checksum = sum(struct.unpack(f"<{(SLOT - 4) // 4}I", slot)) & 0xFFFFFFFF
    return slot + struct.pack("<I", checksum)


def main() -> None:
    factory_mpt, factory_dtb, emmc_sectors, out_mpt, out_dtb = sys.argv[1:]
    open(out_mpt, "wb").write(mpt(open(factory_mpt, "rb").read(), int(emmc_sectors) * SECTOR))
    slot = dtb_slot(open(factory_dtb, "rb").read())
    open(out_dtb, "wb").write(slot + slot)


if __name__ == "__main__":
    main()
