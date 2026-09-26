# H96 Max 3518D (RK3518) — stock board evidence

All of it came from **one root shell on the running stock Android**, over the serial console on
2026-09-05, before anything on the box was modified. `su` is present (`/system/xbin/su`,
`ro.build.type=userdebug`, `ro.debuggable=1`), so unlike `stock/h96max-h313/` nothing here is inferred
from a boot log.

Binaries were pulled as `dd | gzip | base64` per 1 MiB chunk over the 1.5 Mbaud console; gzip's
CRC32 gates each chunk and a whole-range `md5sum` on the box was compared against the host file.
Every file below matched.

## Identity

| Property            | Value                                                                          |
| ------------------- | ------------------------------------------------------------------------------ |
| `ro.product.name`   | `rk3518_box_32` — same as `stock/h96max-h313/`; `_32` is the vendor's 32-bit target |
| `ro.product.model`  | `H96_Max_3518_TS`                                                              |
| `ro.board.platform` | `rk3528`                                                                       |
| Build               | `RZX.V01.20260608.1237`, Android 14, kernel 6.1.118 `#147` (armv7l)            |
| Serial              | `SN26072800001`                                                                |
| SoC OTP             | `524b 3518 …` = literal `RK3518`; BL31 prints `RK3518 SoC`                     |
| PCB silkscreen      | `3518_DG_ZX_V01 20250401`                                                      |

## The tree

| File                | What                                                                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `board.dtb`/`.dts`  | **the factory tree, carved from disk** — `boot` partition (p7) + 18407424, size 98700, located via the Android boot-image v2 header (`header_size=1660`, `dtb_size=98700`). Round-trips through the patched `dtc`. |
| `board-runtime.dtb` | `/sys/firmware/fdt`, i.e. after U-Boot edited it. Kept only to diff against the above                                                                                                                              |

The bootloader's edits, `board-runtime` minus `board`:

- SoC `compatible` rewritten `rockchip,rk3518` → **`rockchip,rk3528a`** — the disk tree never says
  `rk3528a`, so nothing downstream can rely on it once our own U-Boot replaces the vendor's
- two `/memreserve/` entries, `serial-number`, the `memory` node, `chosen/bootargs`, initrd pointers
- `drm_logo` reservation filled in, TVE overscan/`video,*`/`logo,*` properties added
- `local-mac-address = [00 ef 01 1a be a0]` injected into the GMAC node
- `mode-bootloader` / `mode-fastboot` values swapped

## Storage

| File                                   | What                                                                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `gpt.bin`                              | first 34 sectors. Disk is **30777344 sectors = 15,758,000,128 B**; `boot` at LBA 51200, `uboot` at 16384, `trust` at 24576                      |
| `vendor-storage.txt`                   | parsed from `DVKR` at sector 7168: `LAN_MAC 00:ef:01:1a:be:a0`, `SN SN26072800001`, **no WIFI_MAC, no BT_MAC**                                  |
| `emmc-identity.txt`, `emmc-extcsd.txt` | `R1J96N`, manfid `0x13` (Micron), eMMC 5.1, `life_time 0x01 0x01`                                                                               |
| `uboot.img`                            | factory `uboot` partition (p2) — vendor U-Boot 2017.09, two byte-identical 2 MiB halves. **Tracked**: `BOARD_UBOOT_FACTORY` writes it to slot B |

**The other partition images are not tracked.** `trust.img` (p3), `dtbo.img`, `vbmeta.img`,
`baseparameter.img` and `misc.img` are carved from the backup on demand — `.gitignore` keeps `*.img`
out and negates only `uboot.img`, which is model-generic and carries no per-unit data:

```sh
dd if=backup/h96max-3518d/emmc-full.img bs=512 skip=24576 count=8192 of=trust.img   # p3
```

**The eMMC is capped far below its rating.** `DEVICE_TYPE 0x57` advertises HS400/HS200/DDR52, but
the factory tree sets `max-frequency = <50000000>` on `sdhci` with no
`mmc-hs200-1_8v`/`mmc-hs400-1_8v`, so Linux runs it at plain HS 50 MHz 8-bit (`HS_TIMING 0x01`).
Vendor U-Boot uses HS400 200 MHz for its own reads — so the cap is the kernel tree's choice, not the
part's.

**The full eMMC image is not here** — it is `backup/h96max-3518d/emmc-full.img`, gitignored like
every other board's. Take the reserved window from there, not from this directory: it is the only
copy of this box's `SSKR` at sector 8192, and the source of the `FACTORY_DUMP` a full-image write
needs. `docs/h96max-3518d/worklog.md` has how it was finally captured.

## Hardware, as the running system reported it

| File                                                                         | What                                                                       |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `dmesg.txt` (660 KB), `boot.log`                                             | full kernel log, and the serial capture from the DDR banner onward         |
| `kernel-config.txt`                                                          | the vendor kernel's own `/proc/config.gz`                                  |
| `gpio.txt`                                                                   | every claimed line, with names — the single most useful file here          |
| `pinmux-pins.txt`, `pinconf-groups.txt`, `clocks.txt`, `regulators.txt`      | live pin routing, clock tree, regulator tree                               |
| `devices.txt`                                                                | every platform device and the driver bound to it                           |
| `input-devices.txt`                                                          | `hdmi_cec_key`, `ffa90030.pwm` (IR), `adc-keys`                            |
| `usb-topology.txt`                                                           | 4 buses: xhci 480+5000, ehci 480, ohci 12                                  |
| `mpp-nodes.txt`                                                              | `/dev/mpp_service`, `/dev/rga`, 6 dma_heaps, `/dev/dri/card0`+`renderD128` |
| `display.txt`                                                                | `HDMI-A-1 disconnected`, `TV-1 connected` (no TV was attached)             |
| `firmware/`                                                                  | the four Seekwave blobs this box loads                                     |
| `vendor-modules.txt`, `wifi-bt-probe.txt`, `seekwave-fw.txt`, `bt-probe.txt` | the radio stack                                                            |
| `vendor-init.txt`                                                            | `init.rk3528.rc`                                                           |

### Claimed GPIO lines (`gpio.txt`)

| Line             | Name                                | Note                                  |
| ---------------- | ----------------------------------- | ------------------------------------- |
| gpio-139         | `work-red`                          | active low, off at rest               |
| gpio-145         | `work-green`                        | active low, **lit** at rest           |
| gpio-140         | `vcc5v0-otg-regulator`              | one USB port's 5 V switch             |
| gpio-141         | `vcc5v0-host-regulator`             | the other's                           |
| gpio-129         | `vcc-sd`, gpio-142 `vccio_sd`       | rails only — **no SD slot is fitted** |
| gpio-106/107/108 | `reset` / `HOST_WAKE` / `CHIP_WAKE` | the Seekwave radio                    |
| gpio-0           | `pa-ctl`                            | audio amp enable                      |
| gpio-2           | `hpd`                               | HDMI hot-plug detect                  |

### Radio

`swt6621s_wifi` + `skw_sdio_lite` — the **same Seekwave SWT6621S** as `firmware/h96max-h313/`, driver
`VERSION: 2.0.250319-250618.eececbe`. SDIO on `mmc@ffc20000`, control GPIOs off `/seekwcn_boot`
(`seekwave,sv6160lite`).

**Its factory blobs are byte-identical to the other H96 Max's**, except the NV. Measured:
`SWT6621S_DRAM_SDIO.bin` (192816 B), `SWT6621S_IRAM_SDIO.bin` (358776 B) and
`SWT6621S_SEEKWAVE_R00001.bin` (2372 B) all match `stock/h96max-h313/firmware/` exactly.
`SWT6621S_NV_SDIO.bin` differs in **two bytes**, at offsets `0x20` and `0x24` — `0x00` here, `0x01`
there. Neither looks like a MAC; they read as flags.

Note what this does **not** mean: what the overlay _ships_ for DRAM/IRAM is the newer armbian/KICKPI
build (193468 / 360128 B), deliberately, because the factory build asserts on HCI opcode `0x100e`
and leaves BT dead. Comparing a factory blob against a shipped one is what produced an earlier wrong
claim here that the two boards' firmware revisions differed.

**Blobs stay per board regardless.** Identical bytes today are an observation, not a licence to
share a file between boards.

`seekwave_nv_name = "SEEKWAVE_NV_SWT6652.bin"` in the tree names a file that does not exist in
`/vendor/etc/firmware` — same dangling reference as the other H96 Max.

`wlan0` MAC is `fe:fd:fc:c4:f3:27`, locally administered and not in vendor storage — the
`rk35xx-mac-pin` case exactly.

Bluetooth rides the same chip over SDIO. Only `rfkill0`/`phy0` (wlan) exists; there is **no
`hci0`**, and the log says
`Could not find android.hardware.bluetooth.IBluetoothHci/default in the VINTF manifest`, so even
stock Android does not bring BT up on this build.

### IR

`pwm@ffa90030`, `rockchip,remotectl-pwm`, nine `ir_keyN` tables. `ir_key6` is usercode **`0xfb04`**,
the same one the existing H96 Max's remote answers to. `remote_support_psci = <0x00>` — the wake
graft is needed.

## Not collected

Anything needing a TV on HDMI (EDID, CEC, modes) · IR scancodes confirmed against the bundled
remote.

Two entries were struck on 2026-09-05 once the USB cable went on: the **USB-C is the OTG port**
(`dwc3`/`xhci`) and it very much carries data — the box enumerates on it as `Vid=0x2207,Pid=0x350c`
and is bus-powered through it. The USB-A is the `ehci`/`ohci` pair, USB 2.0 only. The full eMMC
image is being read over that link into `backup/h96max-3518d/`.

## `uboot.dtb` / `uboot.dts`

The factory U-Boot's own control device tree, not the kernel's. Carved from the U-Boot FIT in the
eMMC backup — `dd if=backup/h96max-3518d/emmc-full.img bs=512 skip=16384 count=8192`, then the
second `d00dfeed` inside that FIT. Round-trips exactly through our patched `dtc`. It describes
uart2, eMMC timing, `saradc` and `adc-keys` (the download key) — and no USB controllers at all.
