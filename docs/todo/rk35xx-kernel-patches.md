# Armbian's vendor-kernel patches Rockchip never took

Family-wide. Opened 2026-10-20, once `kernel/rk35xx.conf` took `develop-6.1` instead of Armbian's
tree. What Armbian carries on top of Rockchip, checked with `git apply --check` against
`b79032684247`, the commit first pinned, and what of it these boxes would use.

## Where Armbian's tree stands

`rkr7.2` is what Armbian builds since its build commit `81e86244`; its base is `develop-6.1`'s tip,
132 commits past the stable merge first pinned, and the commit `kernel/rk35xx.conf` now builds.
Those carry `rockchip-fephy` fixes (low power while the link is down, `config_init` again on resume,
the txamp default), a vop2 cfg-done rework, a `dwmac-rk-tool` xmit fix and an rkcrypto SHA512 fix.
❓ whether the RK3528's FEPHY is the v1 those fixes key on: the driver reads it from register
`0xfc`.

## Candidates, not in Rockchip's tree

| Commit              | Change                                       | Matters for             |
| ------------------- | -------------------------------------------- | ----------------------- |
| `7a45090`+`5ec5131` | stmmac: no unicast filter without registers  | RK3528, by name         |
| `6d8125e`           | dw-hdmi CEC: EDID read again on replug       | CEC after a TV cycle    |
| `78c67d9`           | hdmi-codec: no capture on HDMI-TX            | mono HDMI in PulseAudio |
| `6a0a08d`+`8c6bb40` | stmmac and phylink resume order              | Ethernet after suspend  |
| `2aa67a0`           | mmc core: NULL `vqmmc` in the voltage switch | one line                |
| `f16cb5f`           | sdhci: request size per the spec             | eMMC speed, to measure  |

Already in Rockchip's tree at the pin, or superseded there: the dw_mmc IDMAC revert, the rga fixes,
the system_monitor NULL check, the vop2 log level. Other SoCs' work (dw-hdmi-qp, hdptx, hdmirx,
panthor, PCIe, panels) does not reach an RK3528.

## The R69's AIC8800

`rkr5.1` had it in-tree, `drivers/net/wireless/aic8800_sdio/`, where
`patches/linux-rockchip/wireless-aic8800-stable-mac.patch` lands. `rkr7.2` dropped it for Radxa's
`aic8800-sdio-dkms` (`radxa-pkg/aic8800`), citing a doubled firmware path. TVBian builds the
`rkr5.1` one, `modules/aic8800.conf`, with the stable-MAC patch; it does not build on 6.12, where
Radxa's is the source.

## Decide

- Which candidates to carry, each validated on a box before it joins `kernel/rk35xx.conf`.
