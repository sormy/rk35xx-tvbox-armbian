# Seekwave SWT6621S firmware

Shared by every board carrying this radio. On TVBian, `package.list` here builds
`tvb-firmware-swt6621s` with both NV variants, and each board's package links
`SWT6621S_NV_SDIO.<compatible>.bin`, the name the driver asks for first, to its antenna's. On an
overlay box each board's `payload.list` installs them to `/lib/firmware/` and picks the variant.

| File                                  | Origin                                                 |
| ------------------------------------- | ------------------------------------------------------ |
| `SWT6621S_DRAM_SDIO.bin`              | H313 and 3518D stock, identical: chip code             |
| `SWT6621S_IRAM_SDIO.bin`              | H313 and 3518D stock, identical: chip code             |
| `SWT6621S_NV_SDIO_STANDALONE_FDD.bin` | H313 stock `SWT6621S_NV_SDIO.bin`: BT stand-alone, FDD |
| `SWT6621S_NV_SDIO_SHARED_TDD.bin`     | 3518D stock `SWT6621S_NV_SDIO.bin`: BT shared, TDD     |
| `SWT6621S_SEEKWAVE_R00001.bin`        | H313 and 3518D stock, identical: RF table              |
| `sv6160lite.nvbin`                    | H313 stock, in its eMMC: BT NV                         |

The factory images assert on the HCI codec reads (`BSPASSERT:hci_tl.c-386`) and never finish
controller init; `0005` answers those opcodes locally, enabled by
`firmware/common/skwbt-options.conf`.

The chip code is one build: `SWT6621S_IRAM_SDIO.bin` stamps it `20250618-15:38:14`. The NV and RF
files carry no version.

Chip code may be upgraded; NV and RF calibration may not.

The two NV variants differ in two bytes — `0x20` `BSP_CFG0` bit0 and `0x24` `BT[0]` — decoded by the
vendor's `SWT6621S_NV_SDIO.ini` in `stock/h96max-h313/firmware/`. That is configuration, not
per-unit identity, which is what makes them shareable.

For a new board, `cmp` its factory NV against both: a match is one `link` line in the board's
`package.list`, a difference gets a new file here named for what it sets.
