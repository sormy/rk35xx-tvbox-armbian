# linux-meson — mainline kernel patches for Amlogic boards

Applied to the `meson64` kernel through `kernel/meson64.conf`; each leaves on the bump that brings
it from upstream.

| Patch  | Holds                                    | Upstream                     |
| ------ | ---------------------------------------- | ---------------------------- |
| `0001` | `meson-gx-socinfo`: GXLX2 `0x2a`, S905L3 | not sent; linux-amlogic list |
| `0002` | staging `vdec` from meson-sm1-codecs     | not for upstream             |
| `0003` | `venc`: DMT modes up to 3840x2160        | `26ce0b87a815`, 6.19         |

## 0001

The S905L3 reports major ID `0x2a`, a gap in the table between G12B and SM1, so `soc0` reads
`Unknown (Unknown)`. The S905L3 is the only GXLX2 part known here, so its package entry matches any
package byte (mask `0x0`), as the S905L entry does for GXLX; the M20 reports `0xc5`.

## 0002

meson-sm1-codecs at `eb7a444`, in-tree: its decoder replaces the staging one and selects `V4L2_H264`
for its H.264 reference lists. Its port to the GXLX2 is `patches/meson-codecs/`, applied on top. The
two encoders, vendor code over compat shims, are built out of tree: `modules/meson-venc.conf`.

## 0003

Upstream's, unchanged. 6.18 caps a DMT mode at 1920 pixels wide, so a monitor's native mode past
that, such as 2256x1504, is pruned as `BAD_HVALUE` and a smaller one picked. meson64-next drops it.
