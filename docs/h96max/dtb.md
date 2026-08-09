# H96 Max RK3518 — `board.dts` changes

Base: the box's factory Android DTB, carved from the eMMC `boot` partition
(`stock/h96max/board.dts`, `rockchip,rk3518-evb1-ddr4-v10`). History and rationale: `worklog.md`.

Rule: every edit must have a functional consumer — factory cosmetics (model string included) stay
untouched.

| Node                | Change                                                                    | Why                                                           |
| ------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/` (root)          | `compatible` prepends `"h96max,rk3518-tvbox"` (factory `model` untouched) | the Seekwave driver keys board-specific firmware names off it |
| `serial@ff9f0000`   | `status` → `okay`, `pinctrl-0 = <&uart0m0_xfer>` added                    | debug-header UART → `ttyS0` console @ 1500000                 |
| `fiq-debugger`      | `status` → `disabled`                                                     | frees `ff9f0000` for `ttyS0`                                  |
| `pwm@ffa90030` (IR) | `remote_support_psci` `0` → `1`                                           | IR as ATF wake source (remote wake)                           |
| `gpu@ff700000`      | `interrupt-names`/`clocks`/`clock-names` → lima style (`bus`/`core`)      | Armbian uses mainline `lima`, not the vendor Mali blob        |
| `gpio-leds`         | node names `work-green`/`work-red` → `power`/`standby`                    | family-uniform `/sys/class/leds` names (shared LED hooks)     |
| `watchdog@ffac0000` | `status` → `okay`                                                         | `/dev/watchdog` for systemd's `RuntimeWatchdogSec` (verified) |

Everything else is factory, unchanged.

Rebuild: `dtc -@ -I dts -O dtb -o board.dtb board.dts` — this tree round-trips cleanly (verify with
`diff <(dtc -I dtb -O dts board.dtb) <(dtc -I dtb -O dts <(dtc -@ -I dts -O dtb board.dts))`).
Decompile warnings are expected.

## Tried and reverted

| Node         | Change tried      | Outcome                                                    |
| ------------ | ----------------- | ---------------------------------------------------------- |
| `cpu-sleep0` | `status` → `okay` | **hangs the boot** ~19 s in, at first real idle — reverted |

Still worth a retry someday, but not by flipping `status`: try a shallower `arm,psci-suspend-param`
or a newer BL31. The serial capture settled the cause: the box hangs silently during MMC/SDHCI init,
no panic and no reset. Evidence: `stock/h96max/armbian-cpuidle-hang-serial.log`; analysis in
`worklog.md`. The watchdog was flipped in the same DTB but is innocent — retested alone afterwards
and it works (now shipped).
