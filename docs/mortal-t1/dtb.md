# Mortal T1 — `board.dts` changes

Base: **the box's own factory Android DTB**, carved from the eMMC `boot` partition
(`stock/mortal-t1/board.dtb`, both `boot.img` copies identical), `rockchip,rk3518-evb1-ddr4-v10`.
History and rationale: `worklog.md`. The tree is generated from stock + `board.patch` by
`./build-board-dts.sh mortal-t1` — edit the patch, never `firmware/mortal-t1/board.dts`.

Rule: every edit must have a functional consumer. Factory values stay untouched unless a named
consumer needs otherwise; `compatible` and `model` are the two that do.

The factory tree differs from the R69's by 26 lines (IR key tables for a different remote, one
`u2phy_otg` status), so this patch is the R69's verbatim but for those two lines — `board.md`:

| Node                      | Change                                                                                                                | Why                                                                                              |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `/` (root)                | `compatible` prepends `"mortal-t1-xr822,rk3518-tvbox"`, appends `"rockchip,rk3528a"`; factory `rockchip,rk3518` kept  | rkmpp has no `rk3518` entry and cannot find the VPU without the alias                            |
| `/` (root)                | `model` → `Mortal T1 XR8223518K-V1.0`                                                                                 | the factory string names the reference EVB, not this box                                         |
| `reboot-mode` (in `grf`)  | adds `mode-maskrom = <0xef08a53c>`                                                                                    | `reboot maskrom` from the OS — factory SPL hands to the BootROM; ❓ untested, it strands the box |
| `serial@ff9f0000` (uart0) | `status` → `okay`, `pinctrl-0 = <&uart0m0_xfer>`                                                                      | debug-header UART → `ttyS0` @ 1500000; header not yet located (`board.md`)                       |
| `fiq-debugger`            | `status` → `disabled`                                                                                                 | 🟡 questionable — frees `ff9f0000` for `ttyS0`; stock runs `ttyFIQ0` on it fine                  |
| `serial@ffa00000` (uart2) | `bluetooth` child added, **commented out**                                                                            | see below: the driver it needs is not merged yet                                                 |
| `pwm@ffa90030` (IR)       | `remote_support_psci` `0` → `1`                                                                                       | IR as ATF wake source (remote powers the box from off)                                           |
| `gpu@ff700000`            | `interrupt-names`/`clocks`/`clock-names` → lima style (`bus`/`core`)                                                  | Armbian uses mainline `lima`, not the vendor Mali blob                                           |
| `vop@ff840000`            | `esmart_lb_mode` `[03]` → `[02]`                                                                                      | 🟡 4K line buffer for Esmart0; `03` caps every window at 2K — no 4K display tried here           |
| `leds`                    | `normal` → `power` (label and node), active-low, `default-state`, `retain-state-*`; `standby` loses its timer trigger | family-uniform `/sys/class/leds` names; polarity ❓ by eye; LEDs survive poweroff/suspend        |
| `watchdog@ffac0000`       | `status` → `okay`                                                                                                     | `/dev/watchdog` for systemd's `RuntimeWatchdogSec` — granted 89.5 s (`board.md`)                 |
| `chosen`                  | **removed**                                                                                                           | u-boot supplies bootargs, and the factory string names `ttyFIQ0`                                 |

> **The `fiq-debugger` graft is optional.** Disabling it frees `ff9f0000` for a conventional
> `ttyS0`; keeping it reaches the same UART as `ttyFIQ0`, which is what stock does. The debugger
> half never initialises either way — the vendor sets `rockchip,irq-mode-enable = <1>`, so
> `IRQ fiq not found` is by design and stock Android logs it too. This board keeps the graft until a
> board runs without it.

Everything else is factory, unchanged. The label is what names the sysfs entry
(`/sys/class/leds/power`); the node was renamed to match so the tree doesn't read as a trap.

## The uart2 `bluetooth` child ships commented out

`firmware/mortal-t1/board.patch` adds the child as a comment, so `board.dts` carries the same text
and the DTB is unaffected.

`SERIAL_DEV_BUS=y` implies `SERIAL_DEV_CTRL_TTYPORT` by Kconfig default, so declaring the child live
hands `ffa00000` to the serdev bus. Nothing binds it until linux-rockchip#526 (the serdev binding
for `hci_h4.c`) merges, and the port is gone from `/dev` meanwhile — leaving neither `hci0` nor a
`ttyS2` for `rk35xx-bt` to run `hciattach` on.

**Exit condition:** when a kernel carrying that binding ships, uncomment the child in `board.patch`,
regenerate with `./build-board-dts.sh mortal-t1`, and drop `rk35xx-bt` + its unit.

## Rebuild

`./build-board-dts.sh mortal-t1` — decompiles the stock DTB, applies `board.patch`, re-emits both
files. Round-trips byte-identically: md5 `6e58584e…` = the shipped DTB = the running box
(re-verified 2026-09-28). No `upstream/mortal-t1/` submission exists yet.

## What U-Boot injects at boot

A tree read from `/proc/device-tree` is the factory tree plus this patch plus what `uboot.itb`
writes (measured 2026-09-28; `u-boot,version` = `2026.04-dirty`, our build):

| U-Boot adds at boot                                                                                    | Factory tree holds                                    |
| ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| `chosen` recreated: `bootargs`, `kaslr-seed`, `linux,initrd-*`, `u-boot,version`, `smbios3-entrypoint` | `chosen` removed by the patch                         |
| —                                                                                                      | root `compatible` and `model` pass through unchanged  |
| —                                                                                                      | no `drm_logo` node (the R69's vendor U-Boot adds one) |
