# Seekwave SWT6621S firmware — provenance

Installed to `/lib/firmware/` by the payload. Mixed origin, deliberately:

| File                          | Origin                                                                             |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `SWT6621S_DRAM_SDIO.bin`      | **KICKPI K3B build** via [armbian/firmware](https://github.com/armbian/firmware) — |
| `SWT6621S_IRAM_SDIO.bin`      | newer chip code; the H96's own build asserts on HCI opcode `0x100e` (BT dead)      |
| `SWT6621S_NV_SDIO.bin`        | this box's Android vendor partition — board NV                                     |
| `SWT6621S_SEEKWAVE_R00001.bin`| this box's Android vendor partition — board RF calibration                         |
| `sv6160lite.nvbin`            | the driver repo (retro98boy/seekwave-swt6621s) — BT NV                             |

Rule: chip code may be upgraded; NV + RF calibration stay the board's own. The driver looks for
board-suffixed names first (`<name>.h96max,rk3518-tvbox.<ext>`, keyed off the DTB compatible),
then these generic names.
