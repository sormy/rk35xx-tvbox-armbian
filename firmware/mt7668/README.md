# MediaTek MT7668 firmware

`package.list` here builds `tvb-firmware-mt7668`, for mt76 and `btmtksdio`, under
`/usr/lib/firmware/updates/mediatek/`.

| File                             | Origin    | Version                   |
| -------------------------------- | --------- | ------------------------- |
| `mt7668_patch_e2_hdr.bin`        | M20 stock | `mp2_1802`, 2019-01-06    |
| `WIFI_RAM_CODE_MT7668.bin`       | M20 stock | `mp2_1801`, 2018-12-27    |
| `WIFI_RAM_CODE2_SDIO_MT7668.bin` | M20 stock | `trp1000800`, 2017-11-08  |
| `EEPROM_MT7668.bin`              | M20 stock | MediaTek's reference blob |

Bluetooth's `mt7668pr2h.bin` is a link to the ROM patch, as the vendor driver uses it: Debian's
`firmware-mediatek` carries an older `7668_trunk` build of 2018-05-17, in a 46 MB package. The
EEPROM is byte-identical in an unrelated S905L2 port, so it is not per-unit calibration.
