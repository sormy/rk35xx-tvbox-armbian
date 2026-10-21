# meson-dw-hdmi — mainline HDMI for the GXLX2 (S905L3)

TVBian's kernel applies `0001` in-tree. An overlay box builds mainline's `meson_dw_hdmi.c` from
Linux 6.18.44 as DKMS package `meson-dw-hdmi-gxlx2`, under its own name because the kernel's is
built in: `firmware/common/fetch-meson-dw-hdmi-src.sh <dir>` stages it with both applied, `0002`
being DKMS-only.

| Patch  | Holds                                                      | Upstream              |
| ------ | ---------------------------------------------------------- | --------------------- |
| `0001` | GXLX2 match data: G12A register access, GXL PHY            | RFC, linux-amlogic    |
| `0002` | the module takes the node from the built-in driver at load | no — built-in kernels |

## 0001

GXLX2 keeps GXL's display pipeline, clocks and PHY, but maps the DesignWare controller directly, as
G12A does. Through GXL's address/data port it reads:

    meson-dw-hdmi c883a000.hdmi-tx: Unsupported HDMI controller (0d0d:0d:0d)

With the patch, against the node at `0xda800000`:

    meson-dw-hdmi-gxlx2 da800000.hdmi-tx: Detected HDMI TX controller v2.01a with HDCP

It is the driver half of "[RFC PATCH 0/2] drm/meson: add HDMI support for GXLX2" (linux-amlogic,
2026-07), without its `meson_drv.c` hunk: the node's GXL fallback compatible is what built-in
meson-drm matches.

## 0002

Built-in meson-dw-hdmi binds the node first, through that same fallback. The tree gives the resets
without `reset-names`, so its bind fails at the first lookup, before it writes anything. At load
this module sets `driver_override` on the node, releases it from the built-in driver and binds it;
meson-drm then binds the whole pipeline. The module takes the resets by index.

Drop both patches, and the package, once the running kernel has GXLX2 support in its own driver.
