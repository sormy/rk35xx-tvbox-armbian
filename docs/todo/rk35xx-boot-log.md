# Boot log cleanup

`dmesg` on the R69 is **1317 lines, 524 err/warn** (2026-08-26, 41 min uptime, kernel 6.1.115 pkg
26.8.3); the H96 Max is 1508/676. An earlier 914/121 reading predates the two entries below. The bar
is _no repeated chatter at any level_, so the total is what matters. Almost none of it is a real
fault; most is drivers announcing normal progress.

Two entries dominate the err/warn count:

- **A `WARNING` plus AArch64 code dump at probe, ~50 lines, on the R69 and the H96 Max.**
  `drivers/gpio/gpiolib-devres.c:327 devm_gpiod_put+0x34/0x44`, reached from `stmmac_mdio_reset` →
  `__mdiobus_register`. These boards have an integrated PHY and no reset line — dmesg says "No PHY
  reset control found" — so the driver puts a GPIO it never got. Benign: ethernet still measures 94
  Mbit/s. An upstream `stmmac` bug, not board data, and **not** the `snps,mtl-rx-config` defect from
  the old submission tree — the shipped tree points those at `&gmac0_mtl_rx_setup` correctly. ✅
  gone on TVBian's kernel, which carries `net-stmmac-skip-absent-mdio-reset-gpio`; the counts here
  are 6.1.115's.
- **`done=1 retry_required=0 sw_retry_required=0 acknowledged=1`, R69 only.** A bare `printk()` per
  management frame in Radxa's driver. ✅ gone: `patches/aic8800/98` deletes it and its RX twin,
  `frame type`.

**Each line at its true level.** Progress a driver reports is `info` or `debug`, never `warn`; a
bare `printk()` has no level and lands at `warn`. Relevel what tells a debugging reader something;
delete only what tells nobody anything.

There is no usable stock baseline for this board, so judge each line on its own terms: does it
describe a fault on **this** board, or an optional thing being absent?

## Triage

| Lines | Source                                   | Verdict                                                          |
| ----: | ---------------------------------------- | ---------------------------------------------------------------- |
|     7 | `rk_gmac-dwmac`                          | optional properties logged as errors — actionable, small         |
|     1 | `AICWFDBG`                               | ✅ errors only (`aic8800/10`); the one left is `99`'s MAC        |
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

### 2. aic8800 — progress as bare `printk()`, R69

121 lines at `warn` or worse on the R69 against 49-60 on the other RK3528 boards (2026-10-22).
Radxa's driver prints its progress with no level: `get_txpwr_max:txpwr_max:18` ×17, `file md5:` ×5,
`rwnx_load_firmware :firmware path =` ×5, `rwnx_plat_bin_fw_upload_android` ×4,
`aicbsp_get_feature … 150 MHz` ×3, an asterisk banner, `tcp_ack_init`, `rwnx_reg_notifier Enter`,
and the SSID and channel of every connect. Give each `pr_debug()` or `pr_info()`, one patch in
`patches/aic8800/`.

### 3. MPP — absent resources reported at `warn`

Every RK3528 board, about a dozen lines: `rkvdec2_init: No … reset resource define` ×4,
`failed on clk_get clk_core`/`clk_cabac`, `mpp_rkvdec2: shared_* is not found!` ×4,
`mpp_rkvenc2: failed to init opp info`/`init_opp_table`, `rkvenc_init: failed to add venc devfreq`,
`rockchip-dmc: failed to get vop …` ×2. The decoders work; the code probes for resources this SoC
does not have. One patch in `kernel/rk35xx.conf`, down to `debug`.

### 4. Small, once each

| Lines | Source                                        | Fix                                   |
| ----: | --------------------------------------------- | ------------------------------------- |
|     4 | `inv-icm42600-spi has no spi_device_id`       | the IMU driver off in the fragment    |
|     4 | `dwmmc_rockchip: No normal/idle pinctrl`      | `dev_dbg`: both states are optional   |
|     3 | `Can't reduce the clock below 52MHz`          | `dev_dbg` in `sdhci-of-dwcmshc`       |
|     2 | `hci0: Failed to read local supported codecs` | ❓ the SWT6621S answers `-56`         |
|     2 | `Direct firmware load for <name>.<board>…`    | the driver's board name tried first   |
|     1 | `optee: api uid mismatch`                     | `CONFIG_OPTEE` off: we ship no OP-TEE |
|     2 | `alsa-restore.rules` stale lines              | `alsa-utils`'s; not ours              |
|     1 | `bpf-restrict-fs: Failed to load BPF object`  | no BPF LSM: `lsm=` or ignore          |

## Order

1. dwmac-rk log levels — small, self-contained, one patch in `kernel/rk35xx.conf`
2. aic8800 progress `printk()`s — the R69's bulk
3. MPP probe chatter
4. the small ones

Keep these out of functional patches. Mixing log-level churn into a fix invites another review round
on something already verified.
