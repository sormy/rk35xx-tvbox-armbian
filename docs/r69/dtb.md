# R69 — `board.dts` changes

Base: **the box's own factory Android DTB** (`stock/r69/board.dts`,
`rockchip,rk3518-evb1-ddr4-v10`). History and rationale: `worklog.md`.

Rule: every edit must have a functional consumer — factory values, including the `model` string,
stay untouched.

| Node                      | Change                                                                           | Why                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `serial@ff9f0000` (uart0) | `status` → `okay`, `pinctrl-0 = <&uart0m0_xfer>`                                 | debug-header UART → `ttyS0` console @ 1500000                                           |
| `fiq-debugger`            | `status` → `disabled`                                                            | frees `ff9f0000` for `ttyS0`                                                            |
| `pwm@ffa90030` (IR)       | `remote_support_psci` `0` → `1`                                                  | IR as ATF wake source (remote wakes the box from off)                                   |
| `gpu@ff700000`            | `interrupt-names`/`clocks`/`clock-names` → lima style (`bus`/`core`)             | Armbian uses mainline `lima`, not the vendor Mali blob                                  |
| `leds`                    | `normal` → `power` (label + node), active-low, `default-state`, `retain-state-*` | family-uniform `/sys/class/leds` names; correct polarity; LED survives poweroff/suspend |
| `watchdog@ffac0000`       | `status` → `okay`                                                                | `/dev/watchdog` for systemd's `RuntimeWatchdogSec`                                      |

Everything else is factory, unchanged. The label is what names the sysfs entry
(`/sys/class/leds/power`); the node was renamed to match so the tree doesn't read as a trap.

## Why the LEDs are driven from userspace

`retain-state-shutdown` and `retain-state-suspended` are not decoration: without them the LED core
sets `LED_CORE_SUSPENDRESUME` / clears the LED at shutdown, and it would fight the `system-shutdown`
/ `system-sleep` hooks that pick which LED is lit. With them, the kernel keeps its hands off and the
hooks are the single authority.

Device tree can express only half of the behaviour anyway — dropping `retain-state-*` turns the blue
LED **off** at poweroff and suspend, but nothing in DT can turn the red one **on**: there is no
property or trigger for a power-state transition (`default-on` fires at probe, `panic-indicator` at
panic). Splitting the policy between the tree and the hooks would put half a problem in each place,
so all of it lives in the hooks.

Rebuild: `dtc -@ -I dts -O dtb -o board.dtb board.dts` — this tree round-trips cleanly (verify with
`diff <(dtc -I dtb -O dts board.dtb) <(dtc -I dtb -O dts <(dtc -@ -I dts -O dtb board.dts))`).

## What the ROCK 2F base used to get wrong

Until 2026-08-09 this DTB was derived from the Radxa ROCK 2F tree. Rebasing onto the factory tree
fixed, without any extra work:

| Was (ROCK 2F)                                                                        | Factory tree                                             |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| CPU OPPs to **2016 MHz**, driven by a `vdd-cpu` i2c regulator the board doesn't have | tops out at the rated **1416 MHz**, no phantom regulator |
| Wi-Fi 32 kHz clock on **gpio3.19**                                                   | `clkm1-32k-out` on **gpio1.19**                          |
| USB 5V host enable on **gpio0.1**                                                    | **gpio4.13** (the pin actually wired)                    |
| No GPIO control of `vcc_sd` / `vcc5v0_otg`                                           | both present                                             |
| Stray `pcie@fe4f0000` + `vcc3v3_pcie20`                                              | absent — RK3518 has no usable PCIe                       |
| eMMC HS200 cap had to be grafted in                                                  | already capped at HS200/100 MHz                          |

IR usercodes, `adc-keys`, thermal trips, PHY and the Wi-Fi reset/host-wake pins were identical in
both, so nothing regressed in the swap.
