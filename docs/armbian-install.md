# `armbian-install` and the factory reserved window

The first 16 MiB of eMMC is a layout, not spare space. `armbian-install` clears it to lay down
partitions, sparing only `DVKR` and `SSKR` — `armbian-config` probes for those two tags and narrows
its wipe when either is found. ✅ confirmed in a shipping build 2026-09-06. An older one narrows
nothing:

```sh
grep -c DVKR /usr/lib/armbian-config/config.functions.sh   # 0 = it will zero the window
```

## The layout

| Sectors     | Armbian name | Holds                                                    | Survives the installer       |
| ----------- | ------------ | -------------------------------------------------------- | ---------------------------- |
| 64–7167     | `idbloader`  | DDR init + SPL                                           | ❌ zeroed, then rewritten    |
| 7168–7679   | `vnvm`       | vendor storage, tag `DVKR` — `LAN_MAC`, `BT_MAC`, serial | ✅ kept                      |
| 7680–8191   | `reserved*`  | includes `uboot_env` at 8128–8191                        | ✅ kept                      |
| 8192–16383  | `reserved2`  | secure storage, tag `SSKR` — HDCP, DRM, attestation keys | ✅ kept                      |
| 16384–20479 | `uboot` A    | `uboot.itb`                                              | ❌ zeroed, then rewritten    |
| 20480–24575 | `uboot` B    | the factory U-Boot's second copy                         | ❌ rewritten by our override |
| 24576–32767 | `trust`      | empty on every board here                                | ✅ **untouched**             |

The ✅ rows are the narrowing build. This box has `grep -c DVKR` = 0, so the wipe covered **all of
0–20479** — window included — and the window came back only by splice (2026-09-30).

Sectors 7168–16383 are factory-provisioned and never recreated. `N` is the device with
`boot0`/`boot1` companions:

```sh
sudo dd if=/dev/mmcblkN bs=1 skip=$((7168*512)) count=4 | tr -d '\0'   # DVKR
sudo dd if=/dev/mmcblkN bs=1 skip=$((8192*512)) count=4 | tr -d '\0'   # SSKR
```

## The backup

**Take a full eMMC backup before writing anything** — it is the only way back to stock.

The box boots without either tag, and they are not worth the same. **`DVKR` is used**:
`rk35xx-mac-pin` reads it through `rk35xx-vendor-storage` and pins the factory `LAN_MAC` onto the
ethernet interface. Its `wifi`/`bt` entries are empty on every board here, so those stay derived.
**`SSKR` is not** — it is reached only by Rockchip's secure-storage TA, and OP-TEE rides inside the
vendor U-Boot FIT that ours replaces. It is kept because it shares the 7168–16383 span with `DVKR`,
so keeping it is one `dd` and dropping it would be two.

| Path                                              | `DVKR` / `SSKR`                                |
| ------------------------------------------------- | ---------------------------------------------- |
| **`armbian-install`** (SD → eMMC migration)       | kept only with the `DVKR` probe — zeroed here  |
| **full-image write** (`wl 0` in maskrom, or `dd`) | overwritten — splice them back from the backup |

Host and box, after whichever path zeroed them:

```sh
dd if=mortal-t1-eMMC-stock.img bs=512 skip=7168 count=9216 of=window.bin   # host
dd if=window.bin of=/dev/mmcblkN bs=512 seek=7168 conv=notrunc,fsync        # box
```

A box with no card slot can only take the second. Afterwards `sudo rk35xx-vendor-storage lan` must
match the box label. Everything else in the window comes from the repo either way: the idbloader to
all five slots, `uboot.itb` to both uboot slots, `trust` zero.

## Nothing recreates the window

Our U-Boot is mainline and carries no vendor-storage driver, so nothing writes `DVKR` back, and
nothing protects those sectors — no block-layer filter, no write-protect group, and a plain `dd` to
sector 7700 sticks. The backup is the only source.
