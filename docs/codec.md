# Hardware video — what the VPU does, and how to prove it

Both boxes carry the same RK3528-class video pipeline. This page is the family reference: which
blocks exist, which formats they are _supposed_ to handle, and the test that decides each cell.
Per-board results live in [`docs/r69/board.md`](r69/board.md#hardware-video) and
[`docs/h96max/board.md`](h96max/board.md#hardware-video) — this page never claims a box works.

> Run end-to-end on the **R69** (2026-08-09); its numbers are in
> [`docs/r69/board.md`](r69/board.md#hardware-video). The H96 Max is still 🟡 until an image with
> its `rk3528a` graft is flashed.

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
and measurements: [below](#h264-encode--an-upstream-mpp-bug-and-the-fix).

**No AV1**, and this is tested, not assumed: MPP refuses it with
`unable to create dec av1 for soc rk3528a unsupported`. Ignore the tool's own banner, which lists
AV1 and VP8 _encode_ — that is the library's compiled-in set, not this SoC's. The honest list is the
`coding caps` line from `mpp_debug=0x10`: dec `0x00f0079c`, enc `0x00100180`.

> **MPP understates this encoder.** Its table marks `vepu540c` `cap_4k = 0` — 1080p only — yet HEVC
> encodes at 4K and 8K on real hardware, `ffprobe`-confirmed at full frame size. Test the
> resolutions; don't trust the capability struct.

## Why the image ships no codec userspace

The vendor kernel exposes the VPU as `/dev/mpp_service` — the userspace **MPP library ABI**, not
V4L2 M2M. Debian's ffmpeg has no `--enable-rkmpp` and there are no `/dev/videoN` M2M nodes for its
`v4l2m2m` wrappers to bind, so stock ffmpeg silently decodes on the four A53s. Baking a
`librockchip_mpp` + ffmpeg stack into the image is exactly the "big compiled userspace" this repo
refuses to carry ([AGENTS.md](../AGENTS.md#phase-3--board-data)) — it is a recipe, below.

What the image _must_ get right is everything a stack can't fix for itself: SoC identity and device
permissions. Both are shipped.

### SoC identity — the whole reason this page exists

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
| H96 Max | `rockchip,rk3528a` — **grafted, ours**      | `rk3528a`         |

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

MPP's own test binaries are the measuring instrument — no ffmpeg required, and `mpi_enc_test`
synthesises its own frames, so encoding needs no sample media at all.

```sh
sudo apt install -y cmake build-essential git       # a bare Armbian has git and gcc, but no g++
git clone --depth 1 https://github.com/rockchip-linux/mpp ~/mpp
cmake -S ~/mpp -B ~/mpp-build -DCMAKE_BUILD_TYPE=Release && nice make -C ~/mpp-build -j4
export PATH="$HOME/mpp-build/test:$PATH"
```

> Build **out of tree**. MPP keeps its own cmake helpers in `mpp/build/`, so pointing cmake's output
> there deletes `merge_objects.cmake` and every later configure dies on
> `Unknown CMake command "merge_objects"` — with the cause already erased.

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
  sample with; leave them 🟡 and say why rather than inventing a result.

Run the matrix **as your normal user, not root** — that run is what proves the udev rule, and it is
the only run that matters, because nothing on this box should decode video as root.

## Known gaps

| Gap                                                                     | Where it bites                                      |
| ----------------------------------------------------------------------- | --------------------------------------------------- |
| **H.264 encode returns size 0** (`hal_h264e_vepu540c_status_check ...`) | encode only; HEVC on the same block is fine         |
| No `venc-opp-table` in either factory tree                              | encoder runs at a fixed 297 MHz, no devfreq scaling |
| `rkvdec2_init: failed on clk_get clk_core` / `No core reset resource`   | noisy boot log, decoder works                       |

The last two are **factory behaviour, not ours** — the box's stock Android dmesg
(`stock/h96max/dmesg.txt`) prints exactly the same lines. Neither has been shown to block anything,
so neither has been grafted: this repo does not add DT nodes with no proven consumer.

### H.264 encode — an upstream MPP bug, and the fix

Stock MPP fails identically on both boards, at every resolution and every rate-control mode:
`hal_h264e_vepu540c_status_check enc not done hw_status: 0x00000000`, output ~40 bytes. Every
prebuilt rkmpp stack inherits this, so "this box can't encode H.264" looks like hardware.

It isn't. The `rkvenc` IRQ increments **exactly once per submitted frame** during a failing H.264
run — identical to a working HEVC run — so the encoder accepts each job and signals completion. The
bug is one line of plumbing: `hal_h264e_vepu540c_status_check()` tests
`reg_ctl.common.int_sta.enc_done_sta`, but the H.264 HAL only ever **writes** the control block —
its lone `MPP_DEV_REG_RD` covers `reg_st`. Nothing ever reads the hardware status word back, so the
check always sees the zero the HAL itself wrote. The H.265 HAL, on the same `vepu540c`, reads it
explicitly from `VEPU540C_REG_BASE_HW_STATUS` — which is why HEVC works and H.264 doesn't.

Adding that read-back **fixes it** — [`mpp/h264e-vepu540c-status.patch`](../mpp/README.md), 12 lines
against `develop`:

```sh
git -C ~/mpp apply /path/to/repo/mpp/h264e-vepu540c-status.patch
make -C ~/mpp-build -j4
```

Measured on the R69 with the patch, `ffprobe`-verified at every frame size, HEVC unaffected:

| H.264 encode |   720p | 1080p |    4K |   8K |
| ------------ | -----: | ----: | ----: | ---: |
| stock MPP    |     ❌ |    ❌ |    ❌ |   ❌ |
| patched      | 116.25 | 55.03 | 14.43 | 3.62 |

Not upstream as of 2026-08-09: `develop` has recent `vepu540c`/RK3528 register work but nothing that
repairs this, `nyanmisaka/mpp` carries the same commits, and no MPP issue describes it.
