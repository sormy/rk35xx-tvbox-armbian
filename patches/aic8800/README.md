# aic8800 — the AIC8800 SDIO driver, as radxa-pkg/aic8800 builds it

`modules/aic8800.conf` builds `src/SDIO/driver_fw/driver/aic8800` at radxa-pkg/aic8800 `fce8802`,
AIC's release `2026_0123_5f7be68d`, with these on top, in order.

| Patch     | Source                                                                            |
| --------- | --------------------------------------------------------------------------------- |
| `01`–`17` | radxa-pkg/aic8800's `debian/patches`, in its series order, cut to the SDIO driver |
| `98`      | ours: two bare `printk()`s, one per management frame, deleted                     |
| `99`      | ours: the MAC from vendor storage or the SoC's OTP id, not random                 |

`10` drops the default log level from every debug class to errors only. `99` is the old driver's
stable-MAC patch, rebased: with it, the R69 keeps `8a:00:33:65:64:b6` across boots.

## Upstream

`01`–`17` are radxa-pkg/aic8800's own. `99` went to `armbian/linux-rockchip`, whose tree carries the
driver, as `#527`: closed without merging. `98`: not submitted.
