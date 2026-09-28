# The eMMC layout, measured

Every number here was read out of the factory backups in `backup/<board>/emmc-full.img`, not taken
from a vendor document.

All three boards have the **same 16 GB eMMC geometry**: 30,777,344 sectors of 512 B, backup GPT at
30,777,343.

## The reserved window, sector by sector

Everything before the first GPT partition, plus the two partitions the bootloader lives in.

| Sectors     | Holds                               | Replication                         | In a factory partition? |
| ----------- | ----------------------------------- | ----------------------------------- | ----------------------- |
| 0–5         | protective MBR, GPT header, entries | backup GPT at the last sector       | no                      |
| 64–5183     | idbloader: DDR init + SPL           | **5 slots, 1024 sectors apart**     | **no**                  |
| 7168–7679   | vendor storage, tag `DVKR`          | **4 copies, 128 sectors apart**     | **no**                  |
| 8192–10239  | secure storage, tag `SSKR`          | **4 copies, 512 sectors apart**     | `security`              |
| 10240–16383 | rest of `security`                  | —                                   | `security`              |
| 16384–19352 | U-Boot FIT, slot A (~1.45 MiB used) | **slot B is a byte-identical copy** | `uboot`                 |
| 20480–23448 | U-Boot FIT, slot B                  | 4096 sectors after slot A           | `uboot`                 |
| 24576–32767 | `trust`                             | **all zero on all three boards**    | `trust`                 |

Three things that surprise people:

- **The idbloader and the vendor storage sit outside every partition.** The factory GPT's first
  partition starts at 8192, so sectors 0–8191 are unpartitioned reserved space. A tool that only
  respects the partition table will happily destroy both.
- **Slot B is not a fallback.** SPL never tries it when slot A fails its hash, and our writes put
  the same FIT in both; the eMMC backup is the fallback.
- **`trust` is empty.** OP-TEE is not in its own partition — it rides inside the U-Boot FIT, which
  is why the boot log checks `optee` right after `uboot`.

### Inside one idbloader copy

Each of the five slots is 1024 sectors; the payload uses ~625 of them, in three pieces:

| Offset in slot | Size     | Holds                  |
| -------------- | -------- | ---------------------- |
| +0             | 1 sec    | `RKNS` ID-block header |
| +3             | 120 sec  | DDR init (the TPL)     |
| +124           | ~500 sec | SPL                    |

**The R69's factory blob fills only two of the five slots**; both H96 Max boards fill all five.
Every copy inside a blob is byte-identical, so there is nothing board-specific about which slot is
used.

## Is it the same on every board?

**The map is. The contents are not.** Same offsets, same replication counts, same partition names;
every structure hashes differently. One difference bites: **a factory blob does not always fill all
five idbloader slots** — one board here fills two — so a box that was migrated differs from its own
factory dump in the slots that were empty before. Each board's hashes and fill count are in its
`board.md`.

## The factory partition table

Identical across all three boards except the `super`/`userdata` split — the R69 gives `super` 2400
MiB, both H96 Max boards 2304 MiB.

| Sectors         | Size          | Name            |
| --------------- | ------------- | --------------- |
| 8192–16383      | 4 MiB         | `security`      |
| 16384–24575     | 4 MiB         | `uboot`         |
| 24576–32767     | 4 MiB         | `trust`         |
| 32768–40959     | 4 MiB         | `misc`          |
| 40960–49151     | 4 MiB         | `dtbo`          |
| 49152–51199     | 1 MiB         | `vbmeta`        |
| 51200–182271    | 64 MiB        | `boot`          |
| 182272–378879   | 96 MiB        | `recovery`      |
| 378880–1165311  | 384 MiB       | `backup`        |
| 1165312–1951743 | 384 MiB       | `cache`         |
| 1951744–2082815 | 64 MiB        | `metadata`      |
| 2082816–2084863 | 1 MiB         | `baseparameter` |
| 2084864–…       | 2304/2400 MiB | `super`         |
| …–30777279      | ~11.4 GiB     | `userdata`      |

## What our image reproduces

`build-image.sh` lays down an Armbian GPT with one `rootfs` starting at sector 32768 — exactly where
the factory `misc` began, so nothing below it is touched by the filesystem.

With `FACTORY_DUMP=<that box's emmc-full.img>` it first restores **the whole window — sector 7168 up
to the first partition** — then lays our bootloader on top. Copying the span wholesale rather than
the regions we happen to have catalogued is the point: anything the vendor puts there survives,
including regions that read back as zero on the three boards measured here.

| Region              | Factory            | Our image                                             |
| ------------------- | ------------------ | ----------------------------------------------------- |
| idbloader           | 5 slots (R69: 2)   | ✅ **all five**, from the board's own blob            |
| vendor storage      | `DVKR` ×4          | ✅ ×4, with `FACTORY_DUMP=` — per unit, never shipped |
| secure storage      | `SSKR` ×4          | ✅ ×4, with `FACTORY_DUMP=` — per unit, never shipped |
| `security` tail     | zero               | ✅ with `FACTORY_DUMP=`                               |
| `uboot`, both slots | factory U-Boot ×2  | ✅ ours ×2 — the two slots are kept identical         |
| `trust`             | zero, one region   | ✅ with `FACTORY_DUMP=` — copies zeros today          |
| everything ≥ 32768  | Android partitions | ➖ replaced by `rootfs` — deliberate                  |

The window's end is read out of the GPT rather than hardcoded, and the build aborts if a base image
ever puts its first partition inside the window.

**Only the first slot boots**; the second is a copy the SPL never falls back to on its own.

`DVKR` and `SSKR` are provisioned in the factory and cannot be recreated, which is why a full backup
comes before a first write.

## Re-deriving this

```sh
IMG=backup/<board>/emmc-full.img
# structures: RKNS idbloader, DVKR/SSKR stores, d00dfeed FITs, ANDROID! boot
python3 - "$IMG" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(64*1024*1024)
M={b'\xd0\x0d\xfe\xed':'FDT',b'DVKR':'DVKR',b'SSKR':'SSKR',b'RKNS':'idb',b'EFI ':'GPT',b'ANDR':'boot'}
for s in range(len(d)//512):
    if d[s*512:s*512+4] in M: print(s, M[d[s*512:s*512+4]])
PY
# the partition table
gdisk -l "$IMG"         # brew's sgdisk is broken on macOS (missing libpopt); gdisk -l works
```

A non-zero-run scan over sectors 0–32767 is what produced the table above; anything not listed there
read back as zero on all three boards.
