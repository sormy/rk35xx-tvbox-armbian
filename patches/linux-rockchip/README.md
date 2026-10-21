# linux-rockchip — kernel patches

Board-independent fixes for Rockchip's vendor kernel. TVBian's `kernel/rk35xx.conf` applies them to
`rockchip-linux/kernel` `develop-6.1`; an overlay box, whose kernel comes from Armbian's `apt`,
cannot. At the branch tip Rockchip has fixed part of two, so those carry only the rest.
`wireless-aic8800-stable-mac` applies to the out-of-tree AIC8800 build, `modules/aic8800.conf`, not
to the kernel.

| Patch                                    | Fixes                                                                       |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `input-remotectl-share-pwm-irq`          | the IR power key as a wake source; Rockchip fixed the IRQ choice            |
| `net-stmmac-skip-absent-mdio-reset-gpio` | a WARN + ~416 lines of trace at every boot; Rockchip fixed one call site    |
| `bluetooth-hci-h4-serdev`                | serdev binding for `hci_h4`, so BT needs no `hciattach` unit                |
| `wireless-aic8800-stable-mac`            | the AIC8800 inventing a fresh MAC each boot                                 |
| `mmc-dw-mmc-rockchip-per-host-inherit`   | `static bool inherit` in `dw_mci_v2_execute_tuning()` — **not needed here** |

**`net-stmmac-skip-absent-mdio-reset-gpio` is worth more than the rest combined for log hygiene.**
One WARN at probe emits its call trace and register dump — ~416 lines, 78% of all err/warn on the
R69 and 82% on the H96 Max.

**`mmc-dw-mmc-rockchip-per-host-inherit` is not applied: neither board can trigger the bug, and
neither can be made to.** It needs two enabled `dw_mci` controllers both taking the v2 tuning path,
contending over a function-scope static.

|         | `mmc@ffc20000` SDIO             | `mmc@ffc30000` SD                     |
| ------- | ------------------------------- | ------------------------------------- |
| R69     | v2-tuning, UHS — **tunes**      | v2-tuning, UHS stripped — never tunes |
| H96 Max | no v2-tuning, UHS — non-v2 path | v2-tuning, UHS stripped — never tunes |

One v2 consumer each, so no contention. Restoring `sd-uhs-*` would not change it either: the R69's
SD has no `vqmmc-supply` and so no 1.8 V switch to run UHS with at all, and the H96 Max's SDIO does
not declare `use-v2-tuning`, so it stays on the non-v2 path however its SD is configured. The bug is
real — a per-host decision in a static is wrong regardless — but we cannot make it fire, and
carrying it unverified would ship a change nothing here has run.
