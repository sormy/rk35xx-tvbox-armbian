# MPP — reaching the video engines

`librockchip_mpp` is the only way in: the vendor kernel exposes the VPU as `/dev/mpp_service`, its
own ABI, not V4L2. Debian doesn't package it, so build it — that also yields the `mpi_dec_test` /
`mpi_enc_test` used below.

```sh
sudo apt install -y cmake build-essential git      # a bare Armbian has gcc, but no g++
git clone --depth 1 https://github.com/rockchip-linux/mpp ~/mpp
cmake -S ~/mpp -B ~/mpp-build -DCMAKE_BUILD_TYPE=Release && nice make -C ~/mpp-build -j4
export PATH="$HOME/mpp-build/test:$PATH"
```

Build **out of tree**: aiming cmake at `~/mpp/build` deletes MPP's own cmake helpers and every later
configure dies on `Unknown CMake command "merge_objects"`. For ffmpeg `--enable-rkmpp`,
`sudo make -C ~/mpp-build install` puts the library in `/usr/local/lib`.

## The blocks

| Block         | Node                 | MPP name   | Handles                                                     |
| ------------- | -------------------- | ---------- | ----------------------------------------------------------- |
| RKVDEC        | `rkvdec@ff740100`    | `vdpu382a` | H.264 · HEVC · VP9 · AVS2 decode — to 8K, 10-bit, AFBC      |
| JPEG decoder  | `jpegd@ff870000`     | `rkjpegd`  | MJPEG decode, to 8K                                         |
| VPU2 (legacy) | `vdpu@ff7c0400`      | `vdpu2`    | MPEG-2 · H.263 · MPEG-4 · H.264 · MJPEG · VP8 · AVS, ≤1080p |
| AVS+ decoder  | `avsd_plus@ff7c1000` | `avspd`    | AVS+                                                        |
| RKVENC        | `rkvenc@ff780000`    | `vepu540c` | H.264 · HEVC · MJPEG encode, to 8K                          |
| RGA2          | `rga@ff850000`       | —          | scale / colour-convert between codec stages                 |

MPP marks this encoder 1080p-only (`cap_4k = 0`); it encodes 4K and 8K anyway.

Known non-fatal noise, identical under stock Android: no `venc-opp-table` (encoder fixed at 297
MHz), and `rkvdec2_init: failed on clk_get clk_core`.

## Gate — does MPP recognise the SoC?

```sh
mpp_debug=0x10 mpi_enc_test -t 7 -w 176 -h 144 -n 1 -o /dev/null 2>&1 | head -3
```

`match chip name: …` passes. `use default chip info` means the root `compatible` names nothing MPP
knows: every encode then dies at `could not found coding type` and decode quietly runs on the CPU.
Fix the tree, not MPP's table.

## Test

`-t` is the numeric `MppCodingType`: MPEG-2 `2`, H.263 `3`, MPEG-4 `4`, H.264 `7`, MJPEG `8`, VP8
`9`, VP9 `10`, HEVC `16777220`, AVS+ `16777221`, AVS `16777222`, AVS2 `16777223`.

```sh
# encode — generates its own frames, no sample media needed
timeout 90 mpi_enc_test -t 7 -w 1920 -h 1080 -n 30 -o /tmp/e.bin
ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/e.bin

# decode — make the clip on any machine with ffmpeg (4K/8K wants a real one)
ffmpeg -y -f lavfi -i testsrc=size=1920x1080:rate=30:duration=2 -pix_fmt yuv420p \
       -c:v libx264 -preset veryfast -b:v 20M -f h264 clip.264
timeout 150 mpi_dec_test -t 7 -i clip.264 -n 30
```

- Run as a **normal user**: the nodes ship root-only, and root hides a missing udev rule.
- **~40 B of output = the HAL never finished.** One codec IRQ per frame in `/proc/interrupts` means
  the hardware did its part, so the bug is in userspace.
- **`mpi_dec_test` takes raw elementary streams, with exactly one exception.** `mpi_dec_utils.c`
  holds a single `strstr(file_in, ".ivf")`, so `.ivf` is the only extension that turns a demuxer on.
  VP8/VP9 must therefore be named `.ivf`; give the same bytes any other name and it parses the IVF
  header as a frame — `Invalid frame marker` for VP9, an `mpp_buf_slot … ver_stride` assertion for
  VP8 — which reads exactly like an unsupported codec. There is no input-container flag; `-f` is the
  _output_ frame format. H.264, HEVC, MPEG-2/4, H.263 and AVS2 are raw ES and need no special name.
- **Anything in another container must be demuxed first**:
  `ffmpeg -i in.mpg -map 0:v:0 -c copy -f data out.es`. `-f data` needs the explicit `-map`, or
  ffmpeg exits with "Output file does not contain any stream". **`mp4` additionally needs
  `-bsf:v h264_mp4toannexb`**
  (`ffmpeg -i in.mp4 -map 0:v:0 -c copy -bsf:v h264_mp4toannexb -f h264 out.264`): mp4 stores H.264
  length-prefixed, and the decoder then reads length bytes as NALs — no fps line and zero codec
  IRQs, which reads like dead hardware.
- **MJPEG decode needs explicit `-w`/`-h`**, or it dies at `mpp_buffer_get … size 0` and reads like
  broken hardware.
- **Always `-pix_fmt yuv420p`** — otherwise ffmpeg hands you VP9 profile 1, which the hardware
  rejects and then spins forever. Hence `timeout` on every run.
- H.264 encode returned empty frames before `rockchip-linux/mpp` commit `905020444` (2026-08-10). ✅
  Confirmed fixed: on `0986d01` the H96 Max 3518D encodes H.264 at 720p/1080p/4K/8K and every stream
  decodes back. The R69's "H.264 encode is broken on `vepu540c`" predates the fix — retest before
  repeating it.

## Playing video to the screen

Debian's `ffmpeg` and `mpv` cannot use this hardware. There is **no `/dev/video*`**: the vendor
kernel ships `CONFIG_ROCKCHIP_MPP_SERVICE` / `CONFIG_ROCKCHIP_MPP_RKVDEC2`, not
`CONFIG_VIDEO_ROCKCHIP_RKVDEC`, so the decoder speaks the MPP ABI on `/dev/mpp_service` and no V4L2
M2M device exists for `h264_v4l2m2m` to bind. Software decode is hopeless — 14 fps for 1080p60
H.264, 6 fps for 4K60 VP9, on four A53s at 1.4 GHz.

**Use `jellyfin-ffmpeg7`, and take the `trixie` build.** It ships `*_rkmpp` decoders and encoders
plus the `scale_rkrga` / `vpp_rkrga` / `overlay_rkrga` filters:

```sh
curl -LO https://repo.jellyfin.org/files/ffmpeg/debian/latest-7.x/arm64/jellyfin-ffmpeg7_7.1.4-3-trixie_arm64.deb
sudo apt install -y ./jellyfin-ffmpeg7_7.1.4-3-trixie_arm64.deb
/usr/lib/jellyfin-ffmpeg/ffmpeg -decoders | grep rkmpp
```

The **bookworm** build of the same version looks identical and is a trap: on trixie it cannot start
(`libvpx.so.7`, `libx265.so.199` missing). Extracted with `dpkg-deb -x` instead of installed, it
silently loads Debian's system `libavcodec` and reports no rkmpp decoders at all — which reads
exactly like "this build has no rkmpp". Check `ldd` for `not found` before believing that.

Decode and display, scaling on the RGA rather than the CPU:

```sh
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
W=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size); H=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)
$FF -re -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v hevc_rkmpp -i clip.mp4 -an \
   -vf "scale_rkrga=w=$W:h=$H:format=bgra,hwdownload,format=bgra" -f fbdev /dev/fb0
```

Measured on the H96 Max 3518D, 2026-09-07, output scaled to a 2256x1504 framebuffer:

| Clip                      | Software | Hardware decode | Decoded **and displayed** | CPU |
| ------------------------- | -------- | --------------- | ------------------------- | --- |
| 1080p60 H.264             | 14 fps   | 157 fps         | ~35 fps                   |     |
| 4K60 VP9                  | 13 fps   | 44 fps          | 24 fps                    | 43% |
| 4K60 HEVC                 | —        | 51 fps          | 27 fps                    | 48% |
| 4K60 HEVC, `mpi_dec_test` | —        | 70 fps          | n/a — decodes to a file   |     |

**Decode is not the bottleneck; `fbdev` is.** Every frame is a full-frame copy into the framebuffer
— 13.6 MB at 2256x1504 BGRA — which roughly halves the rate and burns most of that CPU. Fixing it
needs zero-copy KMS: a DRM-prime frame handed straight to a VOP2 overlay plane. No packaged player
does that here.

**`mpv` is not the answer as packaged.** Debian's `mpv` has no rkmpp hwdec
(`Unsupported hwdec: rkmpp`). Pointing it at Jellyfin's libraries makes the decoders visible, but it
still selects software decode, and it is slower than the ffmpeg path.

Two traps that cost hours:

- **`sudo` strips `LD_LIBRARY_PATH`.** `sudo -E mpv …` silently uses Debian's `libavcodec` and falls
  back to software. The same command without `sudo` behaves completely differently.
- **`mpv --vo=drm` can leave the display dead.** On exit it logged `Failed to restore previous mode`
  and left CRTC 89 with `fb 0` — mode set, no scanout buffer. Everything written to `/dev/fb0`
  afterwards went nowhere, with no error anywhere. `chvt` and rebinding `vtcon1` did not recover it;
  only a reboot did. `modetest -M rockchip -p` showing `fb 0` against a live CRTC is the tell.

## GStreamer with `mppvideodec` — builds and decodes, does not display

Worth having: `mppvideodec` is the only packaged-ish route to hardware decode inside a GStreamer
pipeline, and it decodes correctly. `kmssink` does **not** put a picture on the screen here.

```sh
sudo apt install -y gstreamer1.0-tools gstreamer1.0-plugins-{base,good,bad} \
                    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
git clone --depth 1 -b gstreamer-rockchip https://github.com/nyanmisaka/rk-mirrors.git ~/gst-rk
meson setup ~/gst-rk ~/gst-rk-build --prefix=/usr --libdir=lib/aarch64-linux-gnu --buildtype=release
ninja -C ~/gst-rk-build && sudo ninja -C ~/gst-rk-build install
gst-inspect-1.0 | grep rockchipmpp
```

Needs `librockchip_mpp` and `librga` installed first (`sudo cmake --install ~/mpp-build`). The
`JeffyCN/gstreamer-rockchip` URL in older guides is gone — git asks for a username, which is what a
404 looks like over HTTPS. Builds clean against GStreamer 1.26 despite declaring 1.14.

**Decode is confirmed working** — `GST_DEBUG=mppdec:5` shows `applying NV12 1920x1080 (1920x1088)`
and frames finishing:

```sh
gst-launch-1.0 filesrc location=clip.mp4 ! qtdemux ! h264parse ! mppvideodec ! fakesink
```

One harmless red herring: `gst_video_decoder_negotiate_default: assertion GST_VIDEO_INFO_WIDTH != 0`
fires once before the decoder learns the resolution, then decoding proceeds normally.

**`kmssink` never reaches the panel.** The pipeline runs with zero errors at 4% CPU — plausible for
zero-copy — and the screen keeps showing the console. `kmssink` logs
`connector id = 305 / crtc id = 89 / plane id = 122`, picking the overlay plane, but that plane
never gets a framebuffer committed. Tried and did not help: running as root for DRM master,
`dma-feature=1` on the decoder, `video/x-raw(memory:DMABuf)` caps, `plane-properties="s,zpos=3"`
(the overlay exposes no ZPOS), and unbinding `vtcon1`. `force-modesetting=true` is worse — it fails
to preroll and kills the pipeline with `Internal data stream error`.

The likely blocker is fbcon owning primary plane 57 for the whole session; the untried lever is
keeping fbcon off the display at boot (a `fbcon=map:9`-style argument) so a KMS client can own the
CRTC outright.

**Not pursued further, and deliberately.** The board's job is hardware decode, and that is proven.
Which player reaches the panel with which copy is a userspace choice, not board bring-up — a media
distribution brings its own. `fbdev` via ffmpeg is the working path here, at the copy cost above.

> Beware measuring this with `modetest` while a KMS client runs — it takes DRM master itself and can
> mask or disturb the very commit you are looking for. The reliable check is a human looking at the
> screen.
