# aic8800 — the AIC8800 SDIO driver, as radxa-pkg/aic8800 builds it

`modules/aic8800.conf` builds `src/SDIO/driver_fw/driver/aic8800` at radxa-pkg/aic8800 `fce8802`,
AIC's release `2026_0123_5f7be68d`, with these on top, in order.

| Patch     | Source                                                                            |
| --------- | --------------------------------------------------------------------------------- |
| `01`–`17` | radxa-pkg/aic8800's `debian/patches`, in its series order, cut to the SDIO driver |
| `99`      | ours: the MAC from vendor storage or the SoC's OTP id, not random                 |

`10` drops the default log level from every debug class to errors only. `99` is the old driver's
stable-MAC patch, rebased: with it, the R69 keeps `8a:00:33:65:64:b6` across boots.
