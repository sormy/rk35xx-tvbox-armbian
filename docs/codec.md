# Hardware video — what the VPU does, and how to prove it

Both boxes carry the same RK3528-class video engine: a decoder good to 8K, an encoder for H.264,
H.265 and MJPEG, and a 2D scaler. This page says which blocks exist, what they are _supposed_ to
handle, and how to test each one on your own box. Measured results are per board, in
[`docs/r69/board.md`](r69/board.md#hardware-video) and
[`docs/h96max/board.md`](h96max/board.md#hardware-video) — this page never claims a box works.

Everything here runs through **MPP** — Rockchip's Media Process Platform (`librockchip_mpp`), a
userspace library. The vendor kernel offers the video engine only through MPP's own interface at
`/dev/mpp_service`, not the standard V4L2 one, so every player and transcoder that uses this
hardware goes through MPP. Debian doesn't package it; [`../mpp/`](../mpp/README.md) covers building
it and the one patch it needs.

Both boards have been measured with the full matrix (2026-08-09).

## The blocks

All five are `status = "okay"` in both boards' factory trees and all probe on the vendor kernel. MPP
reaches them through a single `/dev/mpp_service`; RGA has its own node.

| Block         | Node                 | MPP name   | Handles                                                     |
| ------------- | -------------------- | ---------- | ----------------------------------------------------------- |
| RKVDEC        | `rkvdec@ff740100`    | `vdpu382a` | H.264 · HEVC · VP9 · AVS2 decode — **to 8K**, 10-bit, AFBC  |
| JPEG decoder  | `jpegd@ff870000`     | `rkjpegd`  | MJPEG decode — measured to 8K                               |
| VPU2 (legacy) | `vdpu@ff7c0400`      | `vdpu2`    | MPEG-2 · H.263 · MPEG-4 · H.264 · MJPEG · VP8 · AVS, ≤1080p |
| AVS+ decoder  | `avsd_plus@ff7c1000` | `avspd`    | AVS+                                                        |
| RKVENC        | `rkvenc@ff780000`    | `vepu540c` | H.264\* · HEVC · MJPEG encode — measured to 8K              |
| RGA2          | `rga@ff850000`       | —          | scale / colour-convert / rotate between codec stages        |

\* H.264 encode needs a [12-line MPP fix](../mpp/README.md); stock MPP returns empty frames. Cause
and measurements: [below](#h264-encode--a-library-bug-not-a-hardware-limit).

**No AV1**, and this is tested, not assumed: MPP refuses it with
`unable to create dec av1 for soc rk3528a unsupported`. Ignore the format list that `mpi_dec_test`
prints in its usage banner: it names AV1 and VP8 _encode_ too, because that is everything the
library was compiled with, not what this chip has. The honest list is the `coding caps` line from
`mpp_debug=0x10`: dec `0x00f0079c`, enc `0x00100180`.

> **MPP understates this encoder.** Its table marks `vepu540c` `cap_4k = 0` — 1080p only — yet HEVC
> encodes at 4K and 8K on real hardware, `ffprobe`-confirmed at full frame size. Test the
> resolutions; don't trust the capability struct.

## Why the image ships no codec userspace

The vendor kernel exposes the VPU as `/dev/mpp_service` — the userspace **MPP library ABI**, not
V4L2 M2M. Debian's ffmpeg has no `--enable-rkmpp` and there are no `/dev/videoN` M2M nodes for its
`v4l2m2m` wrappers to bind, so stock ffmpeg silently decodes on the CPU instead. Baking a
`librockchip_mpp` + ffmpeg stack into the image is exactly the "big compiled userspace" this repo
refuses to carry ([AGENTS.md](../AGENTS.md#phase-3--board-data)) — it is a recipe, below.

What the image _must_ get right is everything a stack can't fix for itself: SoC identity and device
permissions. Both are shipped.

### SoC identity — MPP has to recognise the chip

MPP picks its codec table by substring-matching `/proc/device-tree/compatible` (`read_soc_name()` →
`check_soc_info()` in `osal/mpp_soc.c`; it reads the **whole** property, NUL separators turned to
spaces). There is no env override.

No MPP release has ever contained an `rk3518` entry. A tree that says only `rockchip,rk3518`
therefore falls through to `mpp_soc_default` — "unknown SoC", whose table claims `vdpu1`/`vdpu2`
decoders and `vepu1`/`vepu2` encoders. Those legacy encoders do not exist on this silicon, so every
encode fails at `mpp_enc_hal_init could not found coding type` and the real RKVDEC/JPEG decoders are
never used. Nothing in the error names the actual cause.

| Board   | Root `compatible` carries                   | Stock MPP matches |
| ------- | ------------------------------------------- | ----------------- |
| R69     | `rockchip,rk3528a` — **factory, untouched** | `rk3528a`         |
| H96 Max | `rockchip,rk3528a` — **added by this repo** | `rk3528a`         |

The H96 Max graft is one appended string ([dtb.md](h96max/dtb.md)); its factory tree named only
`rockchip,rk3518`. It is honest, not a lie to the kernel: this box's own sub-nodes say
`rockchip,rkv-decoder-rk3528` / `rockchip,rkv-encoder-rk3528`, its stock Android boots
`init.rk3528.rc` with an `rk3528-acodec`, and the R69's Android reports `ro.soc.model = RK3528`.

> `rk3528a` and `rk3528` differ in MPP by **one capability: VP9 decode** (`vdpu382a` vs `vdpu382`),
> which is what made the choice of name a real decision rather than cosmetics. **Settled by
> measurement:** the R69 decodes VP9 at 635 / 325 / 85 fps (720p / 1080p / 4K), so `rk3528a` is the
> truthful name for this silicon and the graft is right.

### Device permissions

`/dev/mpp_service`, `/dev/rga` and `/dev/dma_heap/*` are created root-only `0600`, so an
unprivileged process dies at `os_allocator_dma_heap_open ... failed` — and no group membership can
help, because no group is granted anything. `firmware/common/rk35xx-vpu.rules` (shipped to
`/etc/udev/rules.d/`) hands them to group `video`. Confirm your user is in it:

```sh
id -nG | tr ' ' '\n' | grep -x video     # else: sudo usermod -aG video "$USER", then log in again
ls -l /dev/mpp_service /dev/rga /dev/dma_heap/    # want crw-rw---- root video
```

## Getting the tools

The measuring instruments are MPP's own test programs, `mpi_dec_test` and `mpi_enc_test`. They need
no ffmpeg, and `mpi_enc_test` generates its own frames, so encoding can be tested with no sample
media at all.

**Build them following [`../mpp/README.md`](../mpp/README.md)**, which includes the H.264 patch and
the out-of-tree build the sources require. Then:

```sh
export PATH="$HOME/mpp-build/test:$PATH"
```

Prebuilt rkmpp stacks (Armbian's `rockchip-multimedia` packages, `jellyfin-ffmpeg-rockchip`) become
usable the moment the SoC is detected — none has been tested here.

## Test 1 — is the SoC detected

The one check that gates every other cell. `mpp_debug=0x10` turns on MPP's platform log:

```sh
mpp_debug=0x10 mpi_enc_test -t 7 -w 176 -h 144 -n 1 -o /dev/null 2>&1 | head -3
```

- **Good:** `chip name: ... rockchip,rk3528a` then `match chip name: rk3528a`
- **Broken:** `use default chip info` — the DTB graft is missing or a kernel update overwrote the
  DTB; check `/boot/dtb-*/rockchip/board.dtb` against `/usr/local/share/*/board.dtb`

Detection also gates the tools themselves: `-t` is validated by `mpp_check_support_format()`, so an
undetected SoC rejects most codings with `invalid input coding type` before any hardware is touched.

## Test 2 — the format matrix

`-t` takes the numeric `MppCodingType` (`inc/rk_type.h`):

| Format | `-t` | Format | `-t`         |
| ------ | ---- | ------ | ------------ |
| MPEG-2 | `2`  | VP9    | `10`         |
| H.263  | `3`  | HEVC   | `16777220`   |
| MPEG-4 | `4`  | AVS+   | `16777221`   |
| H.264  | `7`  | AVS    | `16777222`   |
| MJPEG  | `8`  | AVS2   | `16777223`   |
| VP8    | `9`  | AV1    | not this SoC |

**Test every resolution, not just 1080p.** The interesting answers on this SoC are at the ends: 8K
decode works, and HEVC encode goes past the 1080p its own capability struct claims.

**Encode** — self-contained, synthetic frames, no sample media needed:

```sh
for res in 1280x720 1920x1080 3840x2160 7680x4320; do
  for t in 7 16777220 8; do                                  # H.264 · HEVC · MJPEG
    timeout 90 mpi_enc_test -t $t -w ${res%x*} -h ${res#*x} -n 30 -o /tmp/e-$t-$res.bin
  done
done
ls -l /tmp/e-*.bin    # ~40 bytes = the HAL never completed a frame, whatever the exit code said
```

`mpi_enc_test` prints an average frame rate — that is the number for the board doc. **Then prove the
bitstream is real and the right size**, because a silently downscaled encode looks like a pass:

```sh
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/e-16777220-7680x4320.bin
timeout 150 mpi_dec_test -t 16777220 -i /tmp/e-16777220-7680x4320.bin -n 30
```

**Decode** needs clips for everything the box can't encode. Generate them anywhere with an ffmpeg —
including the box itself (`apt install ffmpeg`), though 4K/8K software encodes want a real machine:

```sh
for res in 1280x720 1920x1080 3840x2160 7680x4320; do
  ffmpeg -y -v error -f lavfi -i testsrc=size=$res:rate=30:duration=2 -pix_fmt yuv420p \
         -c:v libx264 -preset veryfast -b:v 20M -f h264 h264_$res.264
done
ffmpeg -y -v error -f lavfi -i testsrc=size=1920x1080:rate=30:duration=2 -pix_fmt yuv420p -c:v mpeg2video -f mpeg2video mpeg2.m2v
ffmpeg -y -v error -f lavfi -i testsrc=size=352x288:rate=30:duration=2   -pix_fmt yuv420p -c:v h263 -f h263 h263.263
ffmpeg -y -v error -f lavfi -i testsrc=size=1920x1080:rate=30:duration=2 -pix_fmt yuv420p -c:v libvpx-vp9 vp9.ivf
```

Then, per clip: `timeout 150 mpi_dec_test -t <type> -i <clip> -n 30`, reading the `fps` it reports.

Three traps that cost real time, all harness, none hardware:

- **MJPEG decode needs explicit `-w`/`-h`.** Without them the frame buffer sizes to 0 and it dies at
  `mpp_buffer_get ... size 0` → `failed to get buffer for input frame ret -2`, which reads exactly
  like a broken decoder. It isn't.
- **`-pix_fmt yuv420p` on every clip.** Miss it and ffmpeg hands you VP9 **profile 1**, which the
  hardware rejects (`Profile 1 is not yet supported`) — and then the test **spins forever** rather
  than exiting. Always `timeout`.
- **AVS, AVS+ and AVS2** are claimed by the capability word but have no practical encoder to make a
  sample with; record them as untested (🟡) with the reason, rather than inventing a result.

Run the matrix **as your normal user, not root** — that run is what proves the udev rule, and it is
the only run that matters, because nothing on this box should decode video as root.

## Known gaps

| Gap                                                                     | Where it bites                                      |
| ----------------------------------------------------------------------- | --------------------------------------------------- |
| **H.264 encode returns size 0** (`hal_h264e_vepu540c_status_check ...`) | encode only; HEVC on the same block is fine         |
| No `venc-opp-table` in either factory tree                              | encoder runs at a fixed 297 MHz, no devfreq scaling |
| `rkvdec2_init: failed on clk_get clk_core` / `No core reset resource`   | noisy boot log, decoder works                       |

The last two are **factory behaviour, not something this repo introduced** — the stock Android dmesg
(`stock/h96max/dmesg.txt`) prints exactly the same lines. Neither has been shown to block anything,
so neither has been grafted: this repo does not add DT nodes with no proven consumer.

### H.264 encode — a library bug, not a hardware limit

Stock MPP returns empty frames for H.264 on both boards, at every resolution and rate-control mode
(`hal_h264e_vepu540c_status_check enc not done hw_status: 0x00000000`, ~40-byte output). Every
prebuilt rkmpp stack inherits it, so "this box can't encode H.264" looks like a hardware limit.

It isn't: the encoder completes every frame, and MPP simply never reads the result. A 12-line patch
restores it, giving 116 / 55 / 14 / 3.6 fps at 720p / 1080p / 4K / 8K. Cause, patch and how to apply
it: [`../mpp/README.md`](../mpp/README.md).
