# H96 Max "H313" (RK3518) — stock/vanilla board evidence

The equivalent of `stock/r69/`, with one difference in provenance: the R69's dumps came from a
**root shell on the running stock Android**, while this box's evidence was gathered without one. At
the time we couldn't type into its serial console at all; that turned out to be our wiring, but
**whether this box's Android offers a root shell was never confirmed** — nobody retested it once the
wiring was fixed. So the evidence here comes from three sources instead, and every file below states
which.

**(A) Stock Android, observed live** — the serial capture of a full factory boot:

| File       | What                                                                                  |
| ---------- | ------------------------------------------------------------------------------------- |
| `boot.log` | complete stock Android 14 boot over serial (DDR banner → Android up), ~21k lines. THE |
|            | primary evidence: kernel cmdline, every driver probe, Seekwave GPIOs/firmware names,  |
|            | product properties (`rk3518_box_32` / `H96Max_H313`), eMMC/partition layout           |

Derived from `boot.log` (LF-normalized extracts, mirroring the R69's per-topic dumps):

| File                     | What                                                                          |
| ------------------------ | ----------------------------------------------------------------------------- |
| `cmdline.txt`            | the stock kernel command line (the R69's `cmdline.txt` equivalent)            |
| `dmesg.txt`              | the kernel-log slice of the capture (~20k lines — the `dmesg.txt` equivalent) |
| `props.txt`              | product properties observed in init logs (partial `getprop` substitute)       |
| `firmware-loading.txt`   | every firmware file the Seekwave stack loads (`SWT6621S_*` + calibration)     |
| `wifi-bt-probe.txt`      | the full Seekwave probe trail — chip id, control GPIOs, BT-over-SDIO channels |
| `bootloader-banners.txt` | everything before the kernel: DDR training, SPL, BL31, vendor U-Boot          |

**(B) Hardware identity, read under Armbian** — OS-independent facts, collected over SSH while the
box runs the R69 image from SD (the eMMC's Android is untouched):

| File                                     | What                                                                 |
| ---------------------------------------- | -------------------------------------------------------------------- |
| `cpuinfo.txt`, `meminfo.txt`             | 4× A53; `MemTotal 2015176 kB` — the full 2 GB is real                |
| `soc-serial.txt`                         | SoC cpuid `6a97e688…` (matches stock boot.log; feeds mac-pin)        |
| `emmc-identity.txt`                      | eMMC `R1J96N`, manfid `0x13`, CID/CSD — for the storage-caps work    |
| `sd-identity.txt`                        | the SD used during bring-up (Samsung `JC1S5`, 64 GB)                 |
| `partitions.txt`, `partition-labels.txt` | Android GPT: p7=`boot` (stock DTB), p13=`super` (dynamic partitions, |
|                                          | vendor inside), p14=`userdata`                                       |
| `eth-phy.txt`                            | PHY id `0x00441400` — same RK630-class FEPHY as the R69; the         |
|                                          | `RK630 PHY` DKMS driver already bound                                |
| `cpufreq.txt`, `thermal.txt`             | OPPs 408–2016 MHz; soc-thermal ~48 °C                                |
| `leds.txt`, `input-devices.txt`          | LED classes + input devices as exposed by the **R69 DTB** (wiring    |
|                                          | unverified on this board)                                            |

**(C) Bring-up context (not stock)** — kept here because they document the same hardware:

| File                                 | What                                                             |
| ------------------------------------ | ---------------------------------------------------------------- |
| `armbian-dmesg.txt`, `armbian-*.txt` | the R69-image boot on this board (kernel 6.1.115-vendor-rk35xx); |
|                                      | shows which R69 DTB nodes fire correctly/incorrectly here        |
| `armbian-first-boot-serial.log`      | full serial capture of that first Armbian boot (DDR banner →     |
|                                      | login) — proves the eMMC-SPL-prefers-SD boot path                |

**(D) Extracted from the eMMC dump** (`../../backup/h96max/emmc-full.img` — GPT parsed, partitions
carved, `super` unpacked with `lpunpack`; all images turned out ext4, not EROFS):

| File               | What                                                                          |
| ------------------ | ----------------------------------------------------------------------------- |
| `board.dtb`/`.dts` | **the stock DTB** — two identical FDT copies inside `boot` (p7); 4641-line    |
|                    | dts, `rockchip,rk3518-evb1-ddr4-v10`. The radio runs off `/seekwcn_boot`      |
|                    | (`seekwave,sv6160lite`, chip_en/host_wake/chip_wake = gpio3.10/11/12); the    |
|                    | `wireless-wlan`/`wireless-bluetooth` nodes are **disabled** leftovers         |
|                    | (`ap6275s`!) → stock BT runs over the **SDIO mux**, not UART2                 |
| `firmware/`        | the complete `SWT6621S_*` set from `vendor:/etc/firmware` (10 files incl. the |
|                    | 4 the stock boot loads + NV variants and `.ini` configs)                      |
| `vendor-modules/`  | the Seekwave `.ko`s from `vendor_dlkm` + `modules.{load,dep,alias,softdep}`.  |
|                    | vermagic `6.1.118 … ARMv7` (32-bit — evidence only, can't load on arm64);     |
|                    | `version=1.0.0`, same lineage as the retro98boy DKMS. Stock ships **both**    |
|                    | the full (`skw_sdio`+`skw_bootcoms`+`skw`) and lite                           |
|                    | (`skw_sdio_lite`+`swt6621s_wifi`) stacks; the community DKMS builds the lite  |

Notes for the driver phase: the DTS asks for `seekwave_nv_name = "SEEKWAVE_NV_SWT6652.bin"`, which
does **not** exist in the firmware dir — the driver evidently falls back to `SWT6621S_NV_SDIO.bin`.
The `dtbo` partition holds real overlays (magic `d7b7ab1e`), not yet split — carve if ever needed.

**Not obtainable without booting Android again** (eject SD → stock boots; would also need ADB): live
gpio claims (`/sys/kernel/debug/gpio`), `pinmux-pins`, full `getprop`, `lsmod`, live
`/sys/firmware/fdt`. The carved DTB + `boot.log` cover most of what those provided on the R69.
`iomem.txt` here is address-zeroed (read without root) — re-dump with root if ever needed.
