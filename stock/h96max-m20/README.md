# H96 Max M20 (Amlogic GXLX2) — stock board evidence

The captures came from **one root shell on the running stock Android**, over the serial console on
2026-09-14, before anything on the box was modified. `su` is present (`/system/xbin/su`,
`ro.build.type=userdebug`), so nothing here is inferred from a boot log.

Text was collected into `/data/local/tmp/ev`, then pulled as one `tar | gzip | base64` stream over
the 115200 console. gzip's CRC32 gates the archive and a `md5sum` on the box was compared against
the host file; both matched.

## Identity

| Property            | Value                                                                    |
| ------------------- | ------------------------------------------------------------------------ |
| `ro.product.model`  | `S905LTS`                                                                |
| `ro.board.platform` | `p291` — Amlogic's GXLX2 reference board                                 |
| `ro.fota.platform`  | `S905L3` — the part; `ro.fota.device` is `S905L3_9_ZX001`                |
| BL1 banner          | `GXLX2:BL1:3cfee7:42a5ae;FEAT:ADFD318C:0;…`                              |
| Chip version        | `RevE (2A:E - C5:0)`; `chipid: 0 0 3 c c 0 ed b3 58 a0 0 c5`             |
| Build               | `AZX.V05.20260610.0909`, base `PPR1.180610.011`, built 2026-06-10        |
| Android version     | `ro.build.version.release` reads `14`; the base fingerprint is Android 9 |
| Kernel              | 4.9.113 `#98`, **armv7l**                                                |
| ABI                 | `armeabi-v7a`; `ro.product.cpu.abilist64` is empty                       |
| Serial              | `b0c2d423446fbbe`                                                        |
| PCB silkscreen      | `905_DG_ZX01_V01 2025/09/03`                                             |

## The tree

| File                   | What                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| `factory-multidtb.bin` | the whole Amlogic multi-DTB container, `dd` from `/dev/dtb` and gunzipped. `AML_` v2, 6 DTBs |
| `board.dtb`/`.dts`     | entry 5 of that container — `soc=gxlx2 plat=p291 vari=2g`, the one U-Boot selects            |
| `factory-mpt.bin`      | `reserved`'s first 4 KiB: the vendor MPT the build rewrites                                  |
| `factory-env.bin`      | the 64 KiB `env`, CRC32 first: the env the build edits                                       |
| `uboot-env.txt`        | `strings` of `/dev/block/env`                                                                |
| `boot.log`             | the vendor serial boot, power-on to Android idle                                             |

`board.dtb` is the factory tree, not a runtime one: `/proc/device-tree` on this box reports
`model = "Amlogic"` and `compatible = "amlogic, Gxl"`, and the vendor tree names its pinctrl
`amlogic,meson-gxlx-{aobus,periphs}-pinctrl`.

## Derived on the host

| Path             | From                                                                   |
| ---------------- | ---------------------------------------------------------------------- |
| `loader-stages/` | `bootloader.bin`, split at the offsets BL1 and BL2 read                |
| `acs.bin`        | BL2's DDR and PLL settings, rebuilt as a standalone 804-byte container |
| `firmware/`      | the `vendor` partition of the eMMC image                               |

## Hardware, as the box reports it

| Block      | Evidence                                                                              |
| ---------- | ------------------------------------------------------------------------------------- |
| CPU        | 4× Cortex-A53 (`0xd03`); BL2 sets 1200 MHz, the OPP table lists up to 1752000         |
| RAM        | LPDDR3, rank0+1 1024 MB each @ 600 MHz; `MemTotal: 2054244 kB`                        |
| eMMC       | CID `4501…`, SanDisk `DF4016`, 30777344 sectors = 15.76 GB, plus `boot0`/`boot1`/rpmb |
| SD host    | registered and empty — `/sys/class/mmc_host/sd`; no slot is fitted                    |
| Wi-Fi / BT | MediaTek MT7668 on SDIO, SDR50 @ 50 MHz; vendor `0x37a` device `0x7668`               |
| Ethernet   | `meson6-dwmac c9410000`, internal PHY `0x01814400` at addr 8, 10/100                  |
| USB        | xHCI `c9000000`, 2 ports, USB 2.0 only — `usb3phy: This phy has no usb port`          |
| USB-C      | the OTG port                                                                          |
| Display    | `hdmitx20` Ver 20190815 + CVBS (`meson-gxlx-cvbsout`, `meson-gxlx-vdac`)              |
| GPU        | Mali-450 `mali-utgard d00c0000.mali`                                                  |
| VPU        | `amvdec_*` H.264 · HEVC · VP9 · VC1 · AVS/AVS2 · MPEG2/4 · MJPEG; wave420l encoder    |
| IR         | `meson-remote c8100580.rc`, NEC, 7 vendor keymaps                                     |
| Button     | `gpio_keypad`, key 69 on SARADC                                                       |
| LEDs       | `sys_green`, `sys_red`                                                                |
| Watchdog   | `meson_wdt c11098d0`                                                                  |
| Thermal    | `soc_thermal`, 48 °C at idle                                                          |

## Addresses

Not one of them is a real OUI assignment — every first octet has the locally-administered bit set.
They are nonetheless **stable**: unchanged across the three boots captured here. `mac-addresses.txt`
carries the readings and where each came from.

| Interface | Address             | Source                                              |
| --------- | ------------------- | --------------------------------------------------- |
| `eth0`    | `62:b4:4d:3b:72:e6` | the unifykey `mac` slot, via U-Boot's `mac=` arg    |
| `wlan0`   | `b2:14:26:85:16:d0` | `/sys/class/net/wlan0/address`; `p2p0` matches it   |
| `ap0`     | `b6:14:26:85:16:d0` | `wlan0` with the locally-administered nibble bumped |
| bdaddr    | `72:76:68:48:3f:07` | octets 2–3 are `76 68` — the MT7668 chip id         |

**Ethernet is stored, Wi-Fi and Bluetooth are not.** The unifykey `mac` slot holds
`62:b4:4d:3b:72:e6` verbatim, which is why U-Boot can hand it over on every boot. `mac_wifi` and
`mac_bt` read `exist=none` — hence `key[mac_wifi] not programed yet`. `EEPROM_MT7668.bin` holds
MediaTek's own OUI default `00:0c:43:26:60:48` at offset 4, and `wlan0` does **not** use it.

`persist.service.bdroid.bdaddr` reads `22:22:dd:bb:f2:58` and is not what the stack uses.
`qcom.bluetooth.soc=rome_uart` is set, though there is no Qualcomm part on this box.

## eMMC map

20 Android partitions on a 15388672 KiB device. Offsets are from `partition-map.txt`, printed by the
kernel's own `add_emmc_partition`.

| #     | Name                     | Offset       | Size     | Holds                                    |
| ----- | ------------------------ | ------------ | -------- | ---------------------------------------- |
| p1    | `bootloader`             | `0x00000000` | 4 MiB    | BL2 + the FIP chain, `@AML` at `0x210`   |
| p2    | `reserved`               | `0x02400000` | 64 MiB   | unifykey store and the multi-DTB         |
| p3    | `cache`                  | `0x06c00000` | 1120 MiB |                                          |
| p4    | `env`                    | `0x4d400000` | 8 MiB    | the U-Boot environment                   |
| p5    | `logo`                   | `0x4e400000` | 8 MiB    |                                          |
| p6    | `recovery`               | `0x4f400000` | 24 MiB   |                                          |
| p7–p9 | `misc` `dtbo` `cri_data` | `0x51400000` | 8 MiB ea |                                          |
| p10   | `param`                  | `0x54400000` | 16 MiB   |                                          |
| p11   | `boot`                   | `0x55c00000` | 16 MiB   | Android boot image — kernel + ramdisk    |
| p12   | `rsv`                    | `0x57400000` | 16 MiB   |                                          |
| p13   | `metadata`               | `0x58c00000` | 16 MiB   |                                          |
| p14   | `vbmeta`                 | `0x5a400000` | 2 MiB    |                                          |
| p15   | `tee`                    | `0x5ae00000` | 32 MiB   |                                          |
| p16   | `vendor`                 | `0x5d600000` | 320 MiB  | the Wi-Fi/BT firmware and vendor modules |
| p17   | `odm`                    | `0x71e00000` | 128 MiB  |                                          |
| p18   | `system`                 | `0x7a600000` | 1536 MiB |                                          |
| p19   | `product`                | `0xdae00000` | 128 MiB  |                                          |
| p20   | `data`                   | `0xe3600000` | 11 GiB   |                                          |

**32 MiB between `bootloader` and `reserved` is unpartitioned** — `bootloader` ends at `0x400000`
and `reserved` starts at `0x2400000`. Smaller gaps sit between most later partitions too, so the map
is not contiguous and cannot be reconstructed from sizes alone.

## The loaders

`bootloader.bin` is `/dev/block/bootloader`, dumped and verified byte-exact
(`9d2f1f376efa55ede5034f8aca120f14`). **`mmcblk0boot0` and `mmcblk0boot1` carry the same md5**, so
the box holds three identical copies. Only the first 2 MiB of the 4 MiB partition is non-zero.

The chain inside it, at the offsets U-Boot prints while loading it:

| Stage      | Offset     | Size        |
| ---------- | ---------- | ----------- |
| BL2        | `0x000200` | to `0xc200` |
| FIP header | `0x00c200` | `0x04000`   |
| BL30       | `0x010200` | `0x07600`   |
| BL301      | `0x018200` | `0x02600`   |
| BL31       | `0x01c200` | `0x19600`   |
| BL33       | `0x038200` | `0x60600`   |

BL2 carries DDR3, DDR4 and LPDDR training tables.

## Keys, and what this box does not have

`/sys/class/unifykeys` lists 19 slots. **Two are provisioned:**

| Key    | Size | Value                                  |
| ------ | ---- | -------------------------------------- |
| `usid` | 15   | `b0c2d423446fbbe` — the Android serial |
| `mac`  | 17   | `62:b4:4d:3b:72:e6` — the eth0 address |

Every other slot reads `exist=none`: `mac_wifi`, `mac_bt`, `hdcp`, `hdcp2_tx`, `hdcp2_rx`,
`hdcp22_fw_private`, `widevinekeybox`, `PlayReadykeybox25`, `prpubkeybox`, `prprivkeybox`,
`attestationkeybox`, `attestationdevidbox`, `netflix_mgkid`, `deviceid`, `region_code`, `oemkey`. So
there is **no Widevine, no PlayReady, no Netflix MGK, no HDCP and no Play Integrity attestation
material on this box**. `secure_boot_set` is an efuse slot and reads back as `unknown` through this
interface; its state is ❓.

Searched and **not** present: `DKVR`, `SSKR`. The `reserved` partition's first 16 MiB is
high-entropy data — every 4-character string in it occurs exactly twice — consistent with the
encrypted store the `secure` slots imply, not with plaintext structures.

## The vendor firmware is 32-bit; the silicon and the boot chain are not

`CPU part: 0xd03` is a Cortex-A53, and the AArch32 feature line still carries the ARMv8 crypto
extensions (`aes pmull sha1 sha2 crc32`). BL31 hands off to U-Boot with `Next image spsr = 0x3c9` —
M[4]=0, M[3:0]=0b1001, i.e. **AArch64 at EL2**. Only the vendor kernel and its Android userspace are
AArch32.

## Boot path

`bootcmd=run storeboot` reads the `boot` partition. The stock environment carries an
`aml_autoscript` hook:

```sh
recovery_from_sdcard=if fatload mmc 0 ${loadaddr} aml_autoscript; then autoscr ${loadaddr}; fi;…
```

`recovery_from_udisk` is the same off USB. The serial autoboot prompt
(`Hit any key to stop autoboot`) leaves a 1-second window to the U-Boot shell.

**Every boot already offers a USB gadget, for about 700 ms.** `preboot` runs `switch_bootmode`,
which on a cold boot runs `try_auto_burn=update 700 750` — the `Enter USB burn` and
`Try connect time out 701, 700, 1145` lines in `boot.log`. That window is on the **USB-C port**,
which is the OTG one; the USB-A port is host-only, and under Android `dwc3` is forced to host
(`Configuration mismatch. dr_mode forced to host`), so nothing enumerates once Linux is up.

The button widens it. `upgrade_sadckey` reads SARADC channel 0 and, if it stays below `0x50` across
two reads a second apart, prints `update by key...` and runs the full `update` chain, whose first
step is `usb_burning=update 1000`:

```sh
upgrade_sadckey=saradc open 0; …if saradc get_in_range 0 0x50; then sleep 1; if saradc get_in_range 0 0x50; then echo update by key...; run update; fi;fi;
```

So the button reaches U-Boot's **burning** protocol.
