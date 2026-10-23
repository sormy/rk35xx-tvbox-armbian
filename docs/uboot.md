# The bootloader pair

Two blobs at two sectors, from two different origins. Write them **after** the OS image — write them
first and the image's own loader overwrites them.

| Sector | Blob                                      | Origin                                 |
| ------ | ----------------------------------------- | -------------------------------------- |
| 64     | `boards/<board>/factory_idbloader.bin`    | carved from that box's eMMC — **kept** |
| 16384  | `u-boot.bin`, a FIT — see the table below | built by `./build.sh uboot <board>`    |

## Which loader each board ships

Per-board U-Boot is built from the box's own factory tree, but **swapping a running bootloader for
one that has never booted is not a free change**, so it is enabled per board rather than
family-wide.

`board.conf` decides: `BOARD_UBOOT=rk3528` builds `uboot/rk3528.conf` around the board's own control
tree, `boards/<board>/uboot.dts`, and `tvb-<board>` installs the FIT as `/usr/lib/tvb/u-boot.bin`.
Every board here has one — a shared FIT built from mainline's `rk3528-generic` tree carries no board
DT and no `CONFIG_ADC`, so the recovery button cannot reach Maskrom from U-Boot on it. Whether a
board has ever booted its own belongs in that board's `board.md`.

To enable a board: set `BOARD_UBOOT_DTB_SOURCE` and `BOARD_UBOOT_DTB_TARGET` in its `board.conf`,
write `boards/<board>/uboot.patch` against `factory_uboot.dts`
(`tools/dtcx/dtcx.py --strict <source> factory_uboot.dtb`), run `./build.sh uboot-dtb <board>` and
`./build.sh uboot <board>`, boot it once with serial attached, confirm the recovery button reaches
Maskrom — then commit the tree and set `BOARD_UBOOT=rk3528`.

The image fills all five BootROM idbloader slots (64, 1088, 2112, 3136, 4160) and both U-Boot slots.

## Why the idbloader stays factory

Nothing from the reserved window may be shipped in a generic image: `DVKR` at 7168 and `SSKR` at
8192 are that unit's MAC, serial and keys.

Its DDR tuning is the only one proven stable on this DRAM die; public rkbin DDR blobs are a lottery.
The failure is a random `Synchronous Abort` whose `far` register holds ASCII text — RAM corruption,
not a code bug. Carve it per board; it is the one bootloader file that is not shared.

A backup recovers only the DDR half, so `./build.sh loaders` packs a maskrom USB loader per board
into `boards/<board>/maskrom_loader.bin`: that board's DDR init + Rockchip's `usbplug`.

> ⚠️ **Our U-Boot still serves nothing on USB.** The vendor U-Boot runs rockusb, so `rkdeveloptool`
> can always reach the box. Ours has `# CONFIG_USB is not set` and `CONFIG_NO_NET=y`, so once it
> runs the only interfaces are serial and the recovery button. Adding USB is not a config flip:
> mainline's `rk3528.dtsi` describes no USB controller at all. `docs/todo/rk35xx-uboot-usb.md` has
> the analysis and what fixing it would buy.

## The tree is the factory tree, in names

Same rule as everywhere else here: **follow the factory DTB and graft the minimum.** The U-Boot tree
is built the way `board.dts` is — decompile the box's own blob, then apply a patch whose comments
mark every judgement hunk.

```sh
./build.sh uboot-dtbs            # boards/<board>/factory_uboot.dtb -> factory_uboot.dts, uboot.dts
```

Two stages, each auditable alone:

1. **Mechanical.** `tools/dtcx/` decompiles the blob into `factory_uboot.dts` as the vendor U-Boot's
   source wrote it, every clock and reset cell named from its `rk3528-cru.h`, the board's
   `BOARD_UBOOT_DTB_SOURCE`. The tree is written only once it decompiles back to the blob's own.
2. **Judgement.** `boards/<board>/uboot.patch` turns that into `uboot.dts`, which must compile
   against `BOARD_UBOOT_DTB_TARGET`: mainline's two headers, the reset names mainline spells
   differently (`SRST_PRESETN_SARADC` → `SRST_P_SARADC`), the phase tags (`u-boot,dm-pre-reloc` →
   `bootph-all`, `u-boot,dm-spl` → `bootph-pre-ram`), and every change we make, each with its
   reason.

### Why names, not numbers

A clock reference is `<&cru N>`. The phandle picks the controller; `N` is an index into whichever
driver reads it, and the vendor and mainline number the same clocks differently:

| Node              | vendor    | mainline  |
| ----------------- | --------- | --------- |
| saradc clk/pclk   | 257 / 256 | 195 / 194 |
| eMMC, five clocks | 163–167   | 140–144   |
| sdmmc cclk/hclk   | 407 / 408 | 295 / 296 |

Mainline reads the vendor's 257 as `ACLK_VOP_BIU` and its 163 as `PCLK_UART7`. Nothing errors — the
eMMC just gets clocked against a UART. The blob keeps only the number, but the vendor's source named
it, and the header gives the name back: `CLK_SARADC` is 257 against the vendor's header and 195
against mainline's, so U-Boot's build resolves `uboot.dts` to mainline's numbers by itself.

**A cell whose number has no single name stops the build**, never guessed. `SCMI_*` names are kept
out: they address the `scmi_clk` provider, never a `<&cru N>` cell, and would collide with the low
CRU numbers. Per board: 29 clock and 11 reset cells named, none left unnamed.

### What the patch grafts

- **model** — U-Boot's banner prints it, and three near-identical boxes are otherwise all "Rockchip
  RK3528 Evaluation Board" on a serial console. The root `compatible` is left as the vendor set it:
  nothing in U-Boot matches on it, and the control DT never reaches the kernel.
- **a uart0 node**, and `stdout-path` moved to it. The factory tree holds exactly one serial node —
  uart2 at `ffa00000`, `status = "okay"` — and points `stdout-path` at it. Mainline resolves that
  and binds it, so left alone the console lands on uart2 and the debug header falls silent once
  pre-relocation `DEBUG_UART` output stops. The header is uart0; the factory tree describes no uart0
  because vendor U-Boot reaches it from code instead (`PreSerial: 0, raw, 0xff9f0000`), and mainline
  has no equivalent.
- **`vdd-microvolts` on saradc** — mainline's driver fails probe with no `vref-supply` and no
  explicit reference; the vendor's defaulted.
- **`sdmmc` disabled, 3518D only** — no SD slot; SPL then falls straight through to eMMC.

Upstream's `rk3528-u-boot.dtsi` is deliberately not used: it patches upstream labels a stock-derived
tree has none of, and the phase tags it would add are already present. Ours,
`uboot/rk3528-u-boot.dtsi`, goes in as the board's `-u-boot.dtsi`, the name upstream's Makefile
globs for. It pulls in `rockchip-u-boot.dtsi` for binman, which references only its own labels, and
adds the two nodes the factory tree lacks: `dmc`, without which `dram_init()` fails, and the OTP
`misc_init_r()` reads the CPU ID from.

## The recovery button, and why the tree is per board

🟡 **Implemented and verified in the artifact, not yet on hardware.** Holding the recovery button at
boot should make U-Boot set the download flag and reset into Maskrom, with no serial needed. What
makes it work:

| Piece                                     | Where                                                             |
| ----------------------------------------- | ----------------------------------------------------------------- |
| `CONFIG_ADC` + `CONFIG_SARADC_ROCKCHIP`   | `uboot/rk3528.conf`'s `CONFIGS`, on the generic defconfig         |
| `saradc` node enabled, with a vref        | `boards/<board>/uboot.dts`                                        |
| `setup_boot_mode()` → `board_late_init()` | mainline, already wired; the flag register defaults to `ff370200` |

**The node has to be named `saradc@ffae0000`.** `rockchip_dnl_key_pressed()` walks the ADC uclass
and matches the first six characters of the device name against `saradc`. Upstream `rk3528.dtsi`
calls it `adc@ffae0000`, which the function cannot see — the factory tree calls it `saradc@ffae0000`
and works untouched. One more thing following the vendor gets for free that a hand-written tree has
to discover the hard way.

The eMMC tuning is per board, so the tree cannot be shared either — speed mode, `max-frequency` and
`fixed-emmc-driver-type` all differ between boxes. Each is measured from that box's factory U-Boot
DT in `boards/<board>/factory_uboot.dts`, inherited automatically by a tree derived from one, and
recorded in that board's `board.md`.

The control DTB lives inside the FIT, so a per-board tree means a per-board FIT.

## Why U-Boot is built rather than taken

No third-party prebuilt, every input pinned; the build stamps the tag's commit time, so two builds
of the same inputs match byte for byte.

| Input  | Pin                                                                                     |
| ------ | --------------------------------------------------------------------------------------- |
| U-Boot | mainline tag `v2026.10`, `generic-rk3528_defconfig` (per-board adds the DT and the ADC) |
| BL31   | `rk3528_bl31_v1.21.elf` from `rkbin`, pinned by commit                                  |
| TPL    | `rk3528_ddr_1056MHz_v1.13.bin` — build input only                                       |

- **BL31 v1.20 is the floor.** RK3518 support landed there; older ATF stops at `Unknown SoC`.
  Armbian's own `linux-u-boot-rock-2f-vendor` builds against `rk3528_bl31_v1.17.elf` — its
  `u-boot-metadata-target-1.sh` says so — which is why that loader cannot boot these boxes.
- **Mainline, not the vendor tree.** Rockchip maintains a downstream fork on an old mainline base,
  and Armbian's `rock-2f-vendor` package is a build of it: `CONFIG_ANDROID_BOOTLOADER=y`,
  `CONFIG_ANDROID_AVB=y`, `CONFIG_CMD_BOOT_ANDROID=y`, and `SPL_FIT_GENERATOR=make_fit_atf.sh`, long
  gone from mainline. Its `bootcmd` runs `boot_android`/`bootrkp`, finds `/boot/boot.scr`, bails and
  falls through to PXE. Mainline's `generic-rk3528` boots through bootstd: Armbian's `boot.scr`,
  TVBian's `extlinux.conf`.
- **Switching to it would not fix the MAC.** It does carry vendor storage
  (`CONFIG_ROCKCHIP_VENDOR_PARTITION=y`, `vendor_storage_init` in the blob), but Armbian's defconfig
  has `# CONFIG_ROCKCHIP_SET_ETHADDR is not set` — the option that would turn `LAN_MAC` into
  `ethaddr`. Reading the store and using it for the MAC are two separate switches.
- **The MAC comes from vendor storage.** `patches/u-boot/0003` reads `LAN_MAC` from `mmc0`'s `DVKR`,
  newest intact copy, into `ethaddr` and `eth1addr`; the `cpuid`-derived address is the fallback.
  The kernel gets it as `local-mac-address` and needs no patch of its own.
- **No OP-TEE.** The FIT carries ATF + U-Boot only. BL31 prints one benign
  `No OPTEE provided … opteed_fast`. Re-add with `TEE=` and `rk3528_bl32_v1.06.bin` if ever needed.
- **`ROCKCHIP_TPL=` never reaches the artifact.** Binman assembles TPL+SPL+FIT as one image; only
  the FIT is extracted and the built idbloader discarded. Reproducibility rests on the U-Boot and
  BL31 pins alone.
- **`rkbin` is pinned twice**, in `uboot/rk3528.conf` and `tools/board/build-loader.sh`. Bump both
  together.
- **The U-Boot tag is pinned twice**, `TAG` in `uboot/rk3528.conf` and the commit in the
  `uboot-rk3528-mainline-*` base, whose name says the version. Bump both together.

## Rebuilding

On the host:

```sh
./build.sh uboot <board>                     # -> build/out/uboot/<board>/u-boot.bin
strings -a build/out/uboot/<board>/u-boot.bin | grep -E 'bl31-v|fdt-rk3528'   # identify a blob
# bl31-v1.21 / fdt-rk3528-<board>
```

On the box, slot A then slot B, the eMMC found by its `boot0`/`boot1`:

```sh
sudo dd if=u-boot.bin of=/dev/<disk> bs=512 seek=16384 conv=notrunc,fsync
sudo dd if=u-boot.bin of=/dev/<disk> bs=512 seek=20480 conv=notrunc,fsync
```

It builds in the container like every other step, from a defconfig made on the spot out of
`generic-rk3528_defconfig` with the board's tree named in it, and aborts if a `CONFIGS` symbol does
not survive Kconfig. `boards/<board>/uboot.patch` is the only device-tree source we edit.

Smoke-test before trusting it: the factory idbloader at sector 64 stays put, and the box must come
back; `/proc/device-tree/chosen/u-boot,version` names the U-Boot that booted it.

## What rebuilding cannot fix

**The R69's 1.5 GB ceiling is the factory TPL's, not U-Boot's.** The TPL trains two 1 GB
chip-selects but hands on an `ATAG_DDR_MEM` describing two banks totalling 1.5 GB with nothing above
them. Proven, not assumed: Rockchip's vendor U-Boot sets `CONFIG_BIDRAM=y` — the path that _adds_
any extended-top region the TPL flags — and its `bdinfo` printed those same two banks with
`gd->ram_top_ext_size == 0`. The TPL banner, stock `/proc/iomem` and the stock DTB `/memory` node
all agree.
