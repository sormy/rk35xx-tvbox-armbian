# `gxlimg` — building it on macOS

`repk/gxlimg` creates and signs Amlogic GXL boot images. It replaces Amlogic's closed
`aml_encrypt_gxl`, having been written by reverse engineering it, and unlike that binary it also
reads images back: `-e/--extract`, `-u/--unsign`, `-d/--decrypt`.

That reverse direction is why this repo needs it. The H96 Max M20's DDR and PLL parameters exist
nowhere but inside its own signed BL2, and recovering them means unsigning that BL2 and walking the
ACS structure inside it.

## The patch

`0001-build-on-macos.patch` — two portability fixes, neither Amlogic-specific:

| Fix                                      | Why                                                         |
| ---------------------------------------- | ----------------------------------------------------------- |
| `<endian.h>` → `libkern/OSByteOrder.h`   | macOS has no `<endian.h>`; `amlcblk.c` also needs 16 and 64 |
| `<linux/limits.h>` → `<sys/syslimits.h>` | `PATH_MAX` lives elsewhere on macOS                         |

The endian shim has to cover all six of `htole`/`letoh` at 16, 32 and 64 bits. Grepping the sources
finds only `htole32` and `le32toh`, because `amlcblk.c` builds the rest through token pasting:

```c
#define bh_rd(h, sz, off) (le ## sz ## toh(*(uint ## sz ## _t *)((h) + off)))
```

## Build

On the host:

```sh
./build-amltools.sh          # tools/aml/gxlimg, beside amlcmd
```

The patch is guarded by `__APPLE__`, so Linux builds the same tree unchanged.

## Feeding it an eMMC dump

`-t fip -e` expects a FIP, and a `bootloader` partition dump is not one — the FIP starts 512 bytes
in. Passing the raw dump extracts a BL2 that is 512 bytes out of phase and then fails to unsign with
`Invalid BL2 header`. Skip `0x200` first, and all of BL2, BL30, BL301, BL31 and BL33 come out.
