# H96 Max RK3518 — `board.dts` changes

Base: the box's factory Android DTB, carved from the eMMC `boot` partition
(`stock/h96max/board.dts`, `rockchip,rk3518-evb1-ddr4-v10`). History and rationale: `worklog.md`.

Rule: every edit must have a functional consumer — factory cosmetics (model string included) stay
untouched.

| Node                | Change                                                                    | Why                                                           |
| ------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/` (root)          | `compatible` prepends `"h96max,rk3518-tvbox"` (factory `model` untouched) | the Seekwave driver keys board-specific firmware names off it |
| `/` (root)          | `compatible` appends `"rockchip,rk3528a"`                                 | userspace can't identify this SoC otherwise — see below       |
| `serial@ff9f0000`   | `status` → `okay`, `pinctrl-0 = <&uart0m0_xfer>` added                    | debug-header UART → `ttyS0` console @ 1500000                 |
| `fiq-debugger`      | `status` → `disabled`                                                     | frees `ff9f0000` for `ttyS0`                                  |
| `pwm@ffa90030` (IR) | `remote_support_psci` `0` → `1`                                           | IR as ATF wake source (remote wake)                           |
| `gpu@ff700000`      | `interrupt-names`/`clocks`/`clock-names` → lima style (`bus`/`core`)      | Armbian uses mainline `lima`, not the vendor Mali blob        |
| `gpio-leds`         | node names `work-green`/`work-red` → `power`/`standby`                    | family-uniform `/sys/class/leds` names (shared LED hooks)     |
| `watchdog@ffac0000` | `status` → `okay`                                                         | `/dev/watchdog` for systemd's `RuntimeWatchdogSec` (verified) |

Everything else is factory, unchanged.

## Why the SoC has to name itself `rk3528a`

The factory tree calls this SoC only `rockchip,rk3518` — a name **no MPP release has ever
contained**. `librockchip_mpp` picks its codec table by substring-matching
`/proc/device-tree/compatible`, so it fell through to "unknown SoC", assumed legacy `vepu1`/`vepu2`
encoders this silicon doesn't have, and every hardware encode died at
`mpp_enc_hal_init could not found coding type`. The whole VPU was unreachable to every rkmpp
userspace — ffmpeg, GStreamer, Kodi alike — and nothing in the error said why.

The appended string is the box's own truth, not a lie to the kernel: its `rkvdec`/`rkvenc` nodes are
already `rockchip,rkv-{de,en}coder-rk3528`, its stock Android boots `init.rk3528.rc` with an
`rk3528-acodec`, and the R69 — same SoC, same `35181001` ID — carries `rockchip,rk3528a` in _its_
factory tree, which is why MPP always worked there and never here. It goes **last** so every
existing `rk3518` match still wins; the kernel simply gains a fallback it already understands.

`rk3528a` vs `rk3528` differ in MPP by exactly one capability, VP9 decode — which is what made the
choice real rather than cosmetic. **Measured on the R69** (same silicon, and `rk3528a` from the
factory): VP9 decodes at 635 / 325 / 85 fps at 720p / 1080p / 4K, so `rk3528a` is the truthful name
and this graft is right.

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
