# Boot log cleanup

`dmesg` on the R69 is **1317 lines, 524 err/warn** (2026-08-26, 41 min uptime, kernel 6.1.115 pkg
26.8.3); the H96 Max is 1508/676. An earlier 914/121 reading predates the two entries below. The bar
in `board-validation.md` is _no repeated chatter at any level_, so the total is what matters. Almost
none of it is a real fault; most is drivers announcing normal progress.

Two entries dominate the err/warn count:

- **A `WARNING` plus AArch64 code dump at probe, ~50 lines, on the R69 and the H96 Max.**
  `drivers/gpio/gpiolib-devres.c:327 devm_gpiod_put+0x34/0x44`, reached from `stmmac_mdio_reset` →
  `__mdiobus_register`. These boards have an integrated PHY and no reset line — dmesg says "No PHY
  reset control found" — so the driver puts a GPIO it never got. Benign: ethernet still measures 94
  Mbit/s. An upstream `stmmac` bug, not board data, and **not** the `snps,mtl-rx-config` defect from
  the submission tree — the shipped tree points those at `&gmac0_mtl_rx_setup` correctly. ✅ gone on
  TVBian's kernel, which carries `net-stmmac-skip-absent-mdio-reset-gpio`; the counts here are
  6.1.115's.
- **`done=1 retry_required=0 sw_retry_required=0 acknowledged=1`, R69 only, ~12/h.** A bare
  `printk()` — no level, no prefix — at `aic8800_sdio/aic8800_fdrv/rwnx_tx.c:1835`, so it defaults
  to `KERN_WARNING`. It fires in the TX-confirm path for every management frame, which is what makes
  it periodic. `pr_debug()` with a prefix is the fix, and TVBian builds the driver itself,
  `modules/aic8800.conf`, so it is one patch there.

**Relevelling is not fixing.** A line that tells the reader nothing is noise at any level, and
`dev_dbg` just hides it while leaving the log as long for anyone who raises the level. Delete it, or
make it conditional on something actually being wrong.

There is no usable stock baseline for this board, so judge each line on its own terms: does it
describe a fault on **this** board, or an optional thing being absent?

## Triage

| Lines | Source                                   | Verdict                                                          |
| ----: | ---------------------------------------- | ---------------------------------------------------------------- |
|    17 | `rockchip_drm_dclk_round_rate`           | real defect, misleading text — see `todo/rk35xx-hdmi-modes.md`   |
|     7 | `rk_gmac-dwmac`                          | optional properties logged as errors — actionable, small         |
|   ~30 | `aicbsp` / `rwnx_*` / `AICWFDBG`         | vendor Wi-Fi driver logging progress at error level              |
|     5 | `rockchip-drm` logo/crtc                 | expected: no boot logo configured                                |
|     4 | `SPI driver inv-icm42600-spi`            | not our hardware; in-tree driver missing `spi_device_id` entries |
|     2 | `cacheinfo: Unable to detect ...`        | SoC exposes no cache hierarchy — cosmetic                        |
|     1 | `rockchip-usb2phy ... IRQ index 0`       | expected on this SoC                                             |
|     1 | `rockchip-vop2: failed to init opp info` | no `venc-opp-table`; already recorded as tolerated               |

Beyond err/warn, the rest of the 914 is mostly info-level repetition:
`vcc*_sys: could not add device link regulator.N: -ENOENT` (7), systemd
`skipped, unmet condition check ...` (5 each across half a dozen units), `fake-hwclock-load`
start/finish/deactivate on every boot. Same test applies: does the line tell the reader anything?

### 1. dwmac-rk — optional properties reported as errors

Smallest and clearest, and the one case where the level genuinely is the bug — the driver calls
`dev_err()` when _optional_ DT properties are absent:

```
rk_gmac-dwmac ffbd0000.ethernet: Can not read property: tx_delay.
rk_gmac-dwmac ffbd0000.ethernet: set tx_delay to 0xffffffff
rk_gmac-dwmac ffbd0000.ethernet: Can not read property: rx_delay.
rk_gmac-dwmac ffbd0000.ethernet: set rx_delay to 0xffffffff
rk_gmac-dwmac ffbd0000.ethernet: No PHY reset control found.
rk_gmac-dwmac ffbd0000.ethernet: supply phy not found, using dummy regulator
```

`tx_delay`/`rx_delay` do not apply to an integrated PHY and there is no reset line, so absent is
correct. Drop these rather than demote them; only the "set ... to 0x%x" pair is worth keeping, at
debug. The regulator line comes from the regulator core because dwmac-rk uses `devm_regulator_get()`
where the supply is optional — `devm_regulator_get_optional()` plus a NULL guard removes it, and
`bsp_priv->regulator` is used in exactly one enable/disable pair.

**Do not "fix" this by adding the properties to the DTS** — that would describe hardware the board
does not have.

### 2. DRM dclk warnings

17 lines, one per mode the HDMI PHY cannot clock. The message itself is wrong ("clk_hw ... may be
NULL" — nothing is NULL; `clk_round_rate()` returned negative). Fixing the underlying mode filtering
removes the lines as a side effect. Analysis and the proposed fix are in
`todo/rk35xx-hdmi-modes.md`.

### 3. aic8800 vendor driver

Largest and least tractable — firmware paths, feature flags and interface names from a vendored
driver with no mainline home. Progress reporting that means nothing to anyone but its author; delete
rather than relevel, since the driver logs the same things again at info and debug.

## Order

1. dwmac-rk log levels — small, self-contained, one patch in `kernel/rk35xx.conf`
2. DRM mode filtering — fixes a real defect and 17 lines with it
3. aic8800 — cosmetic only, do last

Keep these out of functional patches. Mixing log-level churn into a fix invites another review round
on something already verified.
