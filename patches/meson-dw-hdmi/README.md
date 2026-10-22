# meson-dw-hdmi — mainline HDMI for the GXLX2 (S905L3)

TVBian's kernel applies `0001` in-tree.

| Patch  | Holds                                           | Upstream           |
| ------ | ----------------------------------------------- | ------------------ |
| `0001` | GXLX2 match data: G12A register access, GXL PHY | RFC, linux-amlogic |

## 0001

GXLX2 keeps GXL's display pipeline, clocks and PHY, but maps the DesignWare controller directly, as
G12A does. Through GXL's address/data port it reads:

    meson-dw-hdmi c883a000.hdmi-tx: Unsupported HDMI controller (0d0d:0d:0d)

With the patch, against the node at `0xda800000`:

    meson-dw-hdmi-gxlx2 da800000.hdmi-tx: Detected HDMI TX controller v2.01a with HDCP

It is the driver half of "[RFC PATCH 0/2] drm/meson: add HDMI support for GXLX2" (linux-amlogic,
2026-07), without its `meson_drv.c` hunk: the node's GXL fallback compatible is what built-in
meson-drm matches.

Drop `0001` once mainline's driver supports the GXLX2.
