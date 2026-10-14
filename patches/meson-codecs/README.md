# meson-codecs — the video decoder and both encoders on the GXLX2 (S905L3)

Patches over `meson-sm1-codecs` at `eb7a444`: its out-of-tree decoder (the mainline staging
meson-vdec with SM1 work) and its two encoders, ported to the S905L3. Three DKMS packages;
`firmware/common/fetch-meson-codecs-src.sh <dir>` stages the one the directory names.

| Patch  | Holds                                                         |
| ------ | ------------------------------------------------------------- |
| `0001` | the decoder runs GXLX2 as G12A-class, minus two G12A settings |
| `0002` | no `EPOLLERR` before CAPTURE streams                          |
| `0003` | `v4l2-h264` built into the decoder                            |
| `0004` | the H.264 encoder (HCodec) on GXLX2                           |
| `0005` | the HEVC encoder (WAVE420L) on GXLX2                          |
| `0006` | MPEG-1/2 canvases mapped once every CAPTURE buffer is queued  |
| `0007` | CAPTURE formats other than NV12M                              |
| `0008` | helpers to reboot a microcode and end a drain with LAST       |
| `0009` | MPEG-4 Part 2                                                 |
| `0010` | MJPEG                                                         |
| `0011` | `wrap_input`: a codec frames its input before the parser      |
| `0012` | VC-1, Advanced profile                                        |
| `0013` | the VIFIFO level read while the VLD is reset                  |
| `0014` | at most 16 CAPTURE buffers above 1080p, for CMA               |
| `0015` | the drain on `STOP` runs from a worker, not the ioctl         |

| Package             | Module        | Device                |
| ------------------- | ------------- | --------------------- |
| `meson-vdec-gxlx2`  | `meson-vdec`  | `meson-video-decoder` |
| `amvenc-avc-gxlx2`  | `amvenc_avc`  | `meson-venc-h264`     |
| `amvenc-hevc-gxlx2` | `amvenc_hevc` | `meson-venc-hevc`     |

## 0001

Amlogic's `media_modules` place GXLX2 (`0x2a`) after G12B, give it G12A's capability entry, and load
G12A's HEVC and VP9 microcode on it. Mainline calls it GXLX and runs it as GXL: HEVC stops after one
frame, VP9 never starts.

Two G12A settings do not hold:

- no HEVC front clock — the factory clock tree has no `clk_hevcb_mux`;
- `HEVC_SAO_CTRL1[15:14]`, `axi_linealign`, at its reset value: 0 or 2 writes the linear output at
  twice the pitch, and Amlogic's driver never writes the field.

HEVC's multi-instance microcode reports on mailbox 0, so the decoder node names SPI 43 `mbox0`.

## 0002

The parser can take a short stream into its FIFO before the first source change; the m2m core then
reports an empty OUTPUT queue with CAPTURE off as `EPOLLERR`, and GStreamer gives up.

## 0004, 0005

The vendor tree already carries `amvenc_avc` and `hevc_enc` nodes, which make platform devices of
those names; the encoders adopt them, with their interrupts and, for WAVE420L, its register window.
The factory kernel probed the WAVE420L on this chip, so GXLX2 joins its chip list.

## 0008-0010

Maxime Jourdan's 5.3-era `codec_mpeg4` and `codec_mjpeg`. Their microcode latches its canvases at
boot, and this decoder boots it before any CAPTURE buffer exists: start raises a source change, and
resume maps the canvases and boots the microcode again. MJPEG writes three planes whatever
`MDEC_PIC_DC_CTRL` says, so it offers YUV420M only, which `0007` lets GStreamer negotiate.
