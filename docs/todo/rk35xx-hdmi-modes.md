# HDMI on RK3528: unclockable modes and slow EDID probes

Two independent defects, found on the R69 (2026-08-14) with a BOE 2256x1504 panel. Neither is board
data — `hdmi@ff8d0000` and `hdmiphy@ffe00000` are identical in `rk3528.dtsi` and every board's DTS
here, so **every board has both**; it just needs a display with a non-standard mode to show the
first.

Measured on the box, not read out of the source.

## 1. The connector advertises modes the PHY cannot clock

`inno_hdmi_phy_clk_round_rate()` walks a hardcoded `pre_pll_cfg_table` and returns `-EINVAL` unless
the pixel clock matches an entry **exactly**. The table holds 22 rates — the standard set:

```
27 33.75 40 59.341 59.4 65 71 74.176 74.25 83.5 85.75 88.75
108 119 148.352 148.5 162 165 296.703 297 593.407 594   (MHz)
```

No DTS here supplies `rockchip,phy-table`, so every board uses that default. 2256x1504p60 needs
235.7 MHz and is not in it — nor are 1920x1200p60 RB (154) or 1600x900p60 RB (97.75), both of which
this panel also advertises.

Nothing prunes them, because **both** filters miss:

- `private_crtc_funcs` — VOP2's `rockchip_crtc_funcs` — has no `.mode_valid` member, so
  `dw_hdmi_rockchip_mode_valid()`'s explicit
  `funcs->mode_valid(crtc, mode, DRM_MODE_CONNECTOR_HDMIA)` hits `if (!funcs->mode_valid) continue;`
  and never runs.
- `vop2_crtc_mode_valid()` (the `drm_crtc_helper_funcs` one) does run at probe and does call
  `rockchip_drm_dclk_round_rate()`, but it only rejects on `clock != request_clock` when
  `vcstate->output_type == DRM_MODE_CONNECTOR_HDMIA`. `output_type` is assigned in
  `dw_hdmi_rockchip_encoder_atomic_check()` — at **commit** time. During probe the CRTC still holds
  its reset state, `output_type` is 0, and the verdict is discarded.

The mode survives, fbcon picks it as preferred, and the failure appears only at commit:

```
[drm:vop2_crtc_atomic_enable] Update mode to 2256x1504p60 ... dclk: 235700000
rockchip_drm_dclk_set_rate:the clk_hw of dclk or parent of dclk may be NULL
[drm:vop2_crtc_atomic_enable] set dclk_vop0 to 235700000, get 148500000
```

Confirmed live: `modetest` reports CRTC 89 driving `2256x1504 ... 235700` while `clk_summary` shows
`dclk_vop0` and its parent `clk_hdmiphy_pixel_io` both at **148500000** — the VOP scans out
2256x1504 timing at 63 % of the required pixel clock.

The warning text is misleading. `rockchip_drm_dclk_round_rate()` prints it whenever
`clk_round_rate()` returns negative, and RK3528 is not in that function's `switch`, so it takes the
plain default. Nothing is NULL.

**Workaround, per display, not baked into the image:** pin a supported mode on the kernel command
line, through a `u-boot-menu` drop-in:

```sh
echo 'U_BOOT_PARAMETERS="$U_BOOT_PARAMETERS video=HDMI-A-1:1920x1080@60"' | sudo tee /etc/u-boot-menu/conf.d/zz-video.conf   # box
sudo u-boot-update   # box
```

Verified: the commit then reads `set dclk_vop0 to 148500000, get 148500000`.

**Fix, as a patch in `kernel/rk35xx.conf`:** reject in `vop2_crtc_mode_valid()` on the rounded rate
rather than the stale output type. `round_rate` is exact-or-`-EINVAL` on this PHY, so `clock <= 0`
suffices and needs no connector type.

## 2. Single-byte EDID probes stall for ~1 s each

Independent of the above, and why boot grows ~5 s whenever a display is attached:

```
dwhdmi-rockchip ff8d0000.hdmi: ddc read failed      ×5, 1.033 s apart
```

With `dyndbg` on, a forced connector re-detect gives **failed=5, timeout=51, err=0** — every failure
a timeout, never a NACK, so the sink refuses nothing. The `xfer:` traces separate by length:

| Read                     | Caller                           | Result               |
| ------------------------ | -------------------------------- | -------------------- |
| `len: 128` block at 0x50 | EDID block read (`READ8` bursts) | succeeds in ~33 ms   |
| `len: 1` at 0x50         | `drm_probe_ddc()` presence check | intermittently hangs |

`dw_hdmi_i2c_wait()` waits `HZ/10` = 100 ms; on timeout `dw_hdmi_i2c_read()` does `retry -= 10`, so
ten timeouts exhaust `retry = 100` and print `ddc read failed` — 10 × ~103 ms = the observed 1.033
s. Five of them is the ~5.2 s.

Not the bus and not board data: `ddc-i2c-scl-high-time-ns = <9625>` / `-low-time-ns = <10000>` (≈51
kHz) are identical in `rk3528.dtsi` and every board's DTS here, the HDMI IRQ counts up throughout
(151 → 219 across one failing probe), and `/sys/class/drm/card0-HDMI-A-1/edid` returns all 256 bytes
afterwards. Forcing a supported mode does **not** help — with `video=HDMI-A-1:1920x1080@60` the
clock is correct and there are still exactly 5 failures and the same boot time.

Cost is boot time only, and only with a display connected.

## Measuring it yourself

```sh
# reproduce the DDC stalls on demand
echo "file drivers/gpu/drm/bridge/synopsys/dw-hdmi.c +p" | sudo tee /sys/kernel/debug/dynamic_debug/control
sudo dmesg -C
echo off    | sudo tee /sys/class/drm/card0-HDMI-A-1/status; sleep 3
echo detect | sudo tee /sys/class/drm/card0-HDMI-A-1/status; sleep 8
dmesg | grep -cE 'ddc read failed|ddc read time out'

# what the CRTC thinks it is driving vs what the clock actually is
sudo modetest -M rockchip -p | head
sudo grep -E 'clk_hdmiphy_pixel_io|dclk_vop0' /sys/kernel/debug/clk/clk_summary
```

## The `esmart_lb_mode` graft is unverified on two of the three boards

`esmart_lb_mode = [02]` (`VOP3_ESMART_4K_2K_2K_MODE`, giving Esmart0 a 4K line buffer) replaced the
factory `[03]` in **all three** `board.dts` files, because the factory value caps every Esmart
window at a 2K line buffer and corrupts the right-hand third of a 4K frame.

- ✅ **H96 Max 3518D** — verified on a 4K TV and on a 2256x1504 monitor, 2026-09-07.
- 🟡 **R69** and **H96 Max** — the graft ships, nobody has put a 4K display on either.

Same SoC family and the same VOP2 block, so it should behave identically — but that earns 🟡, not
✅. Plug a 4K display into each, confirm `3840x2160p60` full-screen with no colour fringe on the
right, and check a 1080p display still comes up clean.
