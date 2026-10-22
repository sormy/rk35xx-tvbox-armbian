# HDMI on RK3528

Rockchip's `develop-6.1` tip, which `kernel/rk35xx.conf` follows, clocks any pixel rate the PHY's
PLL can reach and reads EDID without stalls; both were defects of the vendor kernel Armbian ships.

## The `esmart_lb_mode` graft is unverified on two of the three boards

`esmart_lb_mode = [02]` (`VOP3_ESMART_4K_2K_2K_MODE`, giving Esmart0 a 4K line buffer) replaced the
factory `[03]` in **all three** `board.dts` files, because the factory value caps every Esmart
window at a 2K line buffer and corrupts the right-hand third of a 4K frame.

- ✅ **H96 Max 3518D** — verified on a 4K TV and on a 2256x1504 monitor, 2026-09-07.
- 🟡 **R69** and **H96 Max** — the graft ships, nobody has put a 4K display on either.

Same SoC family and the same VOP2 block, so it should behave identically — but that earns 🟡, not
✅. Plug a 4K display into each, confirm `3840x2160p60` full-screen with no colour fringe on the
right, and check a 1080p display still comes up clean.
