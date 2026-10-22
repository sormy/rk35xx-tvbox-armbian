# AIC8800D80 firmware

`package.list` here builds `tvb-firmware-aic8800`: radxa-pkg/aic8800's D80 set at `fce8802`, every
revision and variant, under `/usr/lib/firmware/aic8800_fw/SDIO/aic8800D80/`, where its driver,
`modules/aic8800.conf`, reads them by these names. They are the names the R69's stock image uses.

| Files                                   | Origin                               | Version                      |
| --------------------------------------- | ------------------------------------ | ---------------------------- |
| `fw_patch_*`, `fw_patch_table_*`        | radxa-pkg/aic8800 `fce8802`          | Aug 01 2025, git `a26f071`   |
| `fmacfw*`, `lmacfw_rf_*`, `aic_*.txt`   | radxa-pkg/aic8800 `fce8802`          | released with the patch      |
| `fw_adid_8800d80_u02.bin`               | radxa-pkg/aic8800, R69 stock identical | —                          |

The R69's chip is U03 and the H variant (`chip rev: 7`, `chip_sub_id=2`): the driver loads
`fmacfw_8800d80_h_u02.bin`, `fw_patch_8800d80_u02.bin` and its `_ext0`.

Why not the R69's stock set, `*_8800d80_u02.bin` of May 14 2025, git `4f0d373`: it is older. It
runs on this driver too, Wi-Fi and Bluetooth up.
