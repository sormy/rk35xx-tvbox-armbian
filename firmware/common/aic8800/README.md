# AIC8800D80 firmware

`package.list` here builds `tvb-firmware-aic8800`. The vendor driver opens the files itself under
`/usr/lib/firmware/aic8800/SDIO/aic8800D80/`, so they install there, outside the kernel's search.
The R69's chip is revision U02: our `fw_adid.bin` is its factory `fw_adid_8800d80_u02.bin`.

| File                 | Origin                     | Version                         |
| -------------------- | -------------------------- | ------------------------------- |
| `fw_adid.bin`        | R69 stock, identical       | —                               |
| `fw_patch.bin`       | armbian/firmware `de63f5a` | Nov 06 2023, git `1f5d13b`      |
| `fw_patch_table.bin` | armbian/firmware `de63f5a` | Nov 06 2023, git `1f5d13b`      |
| `fmacfw.bin`         | armbian/firmware `de63f5a` | released with the patch above   |
| `lmacfw_rf.bin`      | armbian/firmware `de63f5a` | released with the patch above   |
| `aic_userconfig.txt` | armbian/firmware `de63f5a` | `AIC USERCONFIG 2022/0803/1707` |

Why not the factory's: its newer U02 set, `*_8800d80_u02.bin` of May 2025, did not run on the driver
we build, Armbian's `rkr5.1` in-tree AIC8800 (`rwnx v6.4.3.0`).
