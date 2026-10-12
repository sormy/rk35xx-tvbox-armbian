# H96 Max M20: video codecs — worklog

## 2026-10-11 — the decoder on GXLX

- meson-vdec registers `/dev/video0` with H.264, MPEG-1 and MPEG-2. Debian's `firmware-misc-nonfree`
  carries `meson/vdec` but conflicts with `armbian-firmware`; the payload now ships `gxl_h264.bin`
  and `gxl_mpeg12.bin`.
- 1080p H.264, 120 frames: `v4l2-ctl` 98.8 fps; GStreamer `v4l2h264dec` md5 equal to ffmpeg's
  software decode over all 120. MPEG-2 stalls after 2 frames in both. ffmpeg's `h264_v4l2m2m`
  delivered no frame in 10 min and ignored SIGTERM, holding the decoder until killed.

## 2026-10-11 — H.264 decode sizes

- H.264 bit-exact against software at 720p, 1080p and 4K; `v4l2-ctl` 113.6, 98.8 and 30.6 fps.

## 2026-10-12 — HEVC and VP9 on meson-vdec, three bases

- The factory Android loads `amvdec_h265`, `amvdec_vp9` and a WAVE420L HEVC encoder
  (`HevcEnc - wave420l_irq: 53`), so the silicon decodes both and encodes HEVC.
- Armbian's 6.18 kernel already carries LibreELEC's HEVC codec in `meson-vdec`; the GXLX format
  table lists neither HEVC nor VP9, while GXL's lists both. GXLX sits between GXL and GXM in the
  revision enum, so every revision check treats it as GXL.
- Base 1, Armbian's six vdec patches plus HEVC and VP9 in the GXLX table: H.264 bit-exact. HEVC
  parses the stream and decodes frame 0, then stops. GStreamer fails first, `poll error 1` while
  waiting for the source change: the m2m core returns `EPOLLERR` once the OUTPUT queue drains with
  CAPTURE not streaming. VP9: 120 buffers parsed, no interrupt, no resolution change.
- The first HEVC run reset the box silently — empty pstore. `gxl_hevc.bin` and `gxl_vp9.bin`, copied
  seconds before, came back 0 bytes and loaded as `-22` afterwards. Not reproduced since.
- Base 2, base 1 plus Anand Moon's v7 fix series (patchwork series 27712, patches 17 and 19 left out
  as built-in code; 07 and 10 merged by hand over Armbian's parser check): every codec worse — H.264
  61 frames and wrong, HEVC and VP9 none.
- Base 3, `meson-sm1-codecs`' tree (ophub 6.18.55 staging plus SM1 work), with `v4l2-h264.c`
  compiled in since the kernel lacks it: H.264 bit-exact. HEVC via `codec_hevc_ops` and VP9 added to
  GXLX: HEVC decodes frame 0 then stalls, VP9 never starts — the same as base 1, under GStreamer
  this time, so the stall is the HEVC core's, not the client's.
- The factory microcode, from the vendor partition (`/lib/firmware/video/`), is now in
  `stock/h96max-m20/firmware/video/`. `video_ucode.bin` is plaintext: 256-byte package entries, then
  per blob a 512-byte header with magic `EDOC`, name, cpu, format, version and `data_size`. 73
  blobs, version `v0.2.287de0d`; the only `gxlx2` one is AVS2. Its `gxl_hevc.bin` is 36864 bytes and
  `gxl_vp9.bin` 28672, against linux-firmware's 16384, with the same opening words.
- Vendor HEVC and VP9 microcode on base 1 and base 3: no frame. Base 3 wants a second HEVC
  interrupt, `mbox0`; SPI 43, the factory tree's `mailbox_0`, registered and never fired. Reverted.

## 2026-10-12 — the S905L3 is a G12A-class decoder

- Amlogic's `media_modules` place GXLX2 (`0x2a`) after G12B, its capability entry is G12A's field
  for field, and its microcode rule loads `g12a_hevc*` and `g12a_vp9*` on it. Mainline calls the
  chip GXLX and runs it as GXL: the stall after one HEVC frame and the silent VP9 follow.
- The factory has no HEVC back clock (`get gate clk_hevcb_mux control failed`); the core runs on
  `clk_hevc_mux` at 500 MHz.
- On `meson-sm1-codecs`' driver with GXLX2 as a G12A revision minus the front clock: VP9 decodes all
  120 frames, but the linear copy is written at a 3840-byte luma pitch; the same with factory and
  linux-firmware microcode. HEVC never reports a resolution. `gxlx2-as-g12a.diff` here.

## 2026-10-12 — VP9 and HEVC bit-exact at 1080p

- VP9's linear copy at twice the pitch was `HEVC_SAO_CTRL1[15:14]`, `axi_linealign`, which the G12A
  path forces to 2 (64-byte lines). Writing 0 doubles the pitch too; only the reset value is right,
  and Amlogic's `vvp9.c` never writes the field. Left alone on GXLX2: 120 of 120 frames bit-exact.
- HEVC's G12A ops run the multi-instance ucode protocol, which reports on mailbox 0:
  `HEVC mailbox IRQ is unavailable` until the decoder node names SPI 43 `mbox0`. With it, and the
  same `axi_linealign` exemption in the HEVC path, the factory `g12a_hevc_mmu.bin` decodes 1080p
  HEVC bit-exact, 120 of 120.

## 2026-10-12 — the decode matrix, and CMA sized from it

- A poll wrapper keeps `EPOLLERR` off while CAPTURE is not streaming: the parser takes a short clip
  into its FIFO before the first source change, and GStreamer gave up on the empty OUTPUT queue.
  H.264 failed at random sizes until then.
- Each session must start on a fresh module load for now: VP9 at 1080p failed after an earlier
  session in the same load and passed alone.
- `testsrc2`, 2 s, 20 Mbit/s, GStreamer against ffmpeg's software decode, fresh load per clip:
  H.264, HEVC and VP9 bit-exact at 720p, 1080p and 4K once the pool was large enough. 4K: H.264 2.62
  s, HEVC 2.55 s per 60 frames.
- VP9 at 4K failed on `cma: alloc failed` with 256 MiB. Peak CMA per decode at 4K: VP9 254 MiB, HEVC
  139, H.264 124; 15 MiB is in use idle. The factory reserved 60 MiB for the H.264 encoder and 64
  for the HEVC one. The tree now reserves 384 MiB: a 4K VP9 decode plus one encoder.
- MPEG-2 at 720p and 1080p: output, not bit-exact, until the 90 s kill. MPEG-1: GStreamer has no
  `v4l2mpeg1dec`.

## 2026-10-12 — both encoders

- H.264 (HCodec), `meson-sm1-codecs`' `venc-h264` ported: CPU type GXLX2, the `gxlx-vdec` node, the
  GIC through its interrupt parent, and `v4l2_m2m_buf_copy_metadata()`'s 6.18.44 signature. The
  vendor tree's `amvenc_avc` node already makes a platform device of that name (`-EEXIST`), with the
  `mailbox_2` interrupt the encoder needs; the module adopts it. Microcode from the factory
  `h264_enc.bin`: `gxl_h264_enc`, `ga_h264_enc_cabac`. Clock level 6 is fclk_div3, 667 MHz.
- `h264_v4l2m2m`, 60 frames of `testsrc2` at 8 Mbit/s, PSNR against the source: 720p 51.5 dB, 1080p
  45.6 dB. The driver caps at 1920x1088, as Amlogic specifies the block: 4K is ➖.
- HEVC (WAVE420L), `venc-hevc` ported the same way, plus GXL's clock IDs (`FCLK_DIV3` 5, `FCLK_DIV5`
  7), GXL's reset base `0xc1104400`, and the vendor `hevc_enc` node adopted for its SPI 187 and
  `io_reg_base` at `0xc8810000`. The vendor's chip list for the encoder lacks GXLX2 though the
  factory kernel probed it here (`wave420l_irq: 53`); added. Firmware: Chips&Media's `monet.bin`
  from StarFive's SDK, md5 `dbfaf48e103e1bf7f1101b49c5e3bbde`, as `meson-sm1-codecs` pins it; the
  factory dump carries none.
- `hevc_v4l2m2m` at 8 Mbit/s: 720p 51.1 dB, 1080p 44.9 dB, 4K 38.7 dB in 11.3 s for 60 frames.

## 2026-10-12 — MPEG-1/2 and packaging

- GXLX2 runs `gxl_mpeg12_multi` by the vendor rule. `meson-sm1-codecs`' multi codec with the DMC at
  `0xc8838000` (G12A's is `0xff638000`; the mask bit, 21, and `DMC_CHAN_STS`, `0xc8`, match the
  vendor's G12A-and-later path): the 8 KiB factory blob must be padded to the loader's 16 KiB; then
  one picture at ~24 dB against software, and no second.
- The single-instance codec with linux-firmware's `gxl_mpeg12.bin`, now as G12A-class: 3 frames at
  ~5 dB. The multi codec is the vendor's path and stays in the table.
- Shipped as three DKMS packages from `meson-sm1-codecs` at `eb7a444` plus `patches/meson-codecs/`;
  `fetch-meson-codecs-src.sh` reproduces the tested trees byte for byte. Microcode in the payload:
  factory `g12a_hevc_mmu`, `g12a_vp9`, `gxl_mpeg12_multi` (padded), `gxl_h264_enc`,
  `ga_h264_enc_cabac`; linux-firmware `gxl_h264`; `monet.bin`.

## 2026-10-12 — the shipped packages

- After `rk35xx-update` and a reboot the decoder and both encoders load from DKMS on their own; the
  encoders once their OF match tables were exported. The vendor compatibles carry a space, which the
  device modalias and modpost both turn into `_`.
- The matrix on the installed modules: H.264, HEVC and VP9 bit-exact at 720p, 1080p and 4K; the
  encoders as before.
- Eight decodes in a row in one module load, H.264, HEVC and VP9 mixed, 720p to 4K: all bit-exact.
  The earlier failures after a previous session were the poll race, not left-over state.

## 2026-10-12 — MPEG-1/2

- The first MPEG-2 picture was right all along: 73.5 dB luma against software frame 0. The 24 dB
  came from comparing it with frame 1.
- The stall: the multi codec mapped canvases for the CAPTURE buffers queued at its first run, two,
  and never again. Two references and a picture in flight need three; `find_free()` returned -1 with
  eight buffers queued. Mapped once every CAPTURE buffer is queued (`0006`): MPEG-2 at 720p and
  1080p, 60 of 60, 66.4 and 67.5 dB.
- MPEG-1: GStreamer has no `v4l2mpeg1dec`, but `v4l2mpeg2dec` takes `mpegversion=1`: 60 of 60, 66.7
  and 67.6 dB. `v4l2-ctl` and ffmpeg's `mpeg1_v4l2m2m` decode nothing; ffmpeg's `h264_v4l2m2m` 3
  frames of 60.

## 2026-10-12 — MPEG-4 and MJPEG

- Jourdan's `codec_mpeg4` and `codec_mjpeg` (Khadas Fenix `0116`, `0117`) on GXLX2, as ported:
  MPEG-4 2 frames of 60 at 5 dB, MJPEG 56 at 4.7 dB. Both outputs all zeros.
- Not the canvas block mode (`VDEC_ASSIST_CANVAS_BLK32`, as MPEG-2 on G12A): same PSNR with and
  without, and no difference once decoding worked. Not the microcode: factory `gxl_mjpeg`,
  `g12b_mjpeg` and linux-firmware's `gxl_mjpeg` all zeros; factory `gxl_xvid` is byte for byte
  linux-firmware's `gxl_mpeg4_5`.
- MJPEG had 8 buffers for the microcode's 4 canvas slots: `amvdec_set_canvases()` failed on the
  fifth and freed them all, unchecked. Fixed, still zeros.
- The cause: this decoder starts at OUTPUT STREAMON, before any CAPTURE buffer exists, and the
  legacy microcode latches its canvases when it boots. A source change from start, then canvases in
  resume, still zeros; rebooting the microcode once they are mapped (`vdec_ops->resume` plus
  `esparser_power_up()`): MJPEG luma 39-43 dB.
- MJPEG chroma: the first 640 bytes of each NV12 chroma row were exactly the V plane. The microcode
  writes planar U then V into one canvas and ignores `MDEC_PIC_DC_CTRL[17]`, even set after boot and
  per frame. Amlogic's V4L2 driver converts with GE2D. YUV420M only.
- GStreamer could not negotiate YUV420M: element templates come from the CAPTURE formats enumerated
  before OUTPUT is set, and S_FMT on OUTPUT kept NV12M for a codec without it, so REQBUFS made two
  planes for three. With both fixed, and the V plane sized a quarter (it was a half): MJPEG 60 of
  60, 72.6 dB at 720p, 73.8 dB at 1080p.
- MPEG-4: GStreamer dropped frame 1 as "too many buffers": timestamps were taken in order, and the
  first input buffer holds only the VOL header. Matched by the stream offset the microcode reports
  (`MP4_OFFSET_REG`): every frame on its source frame, 65-73 dB.
- Neither codec ended: no `async_drain`. MPEG-4 with `visual_object_sequence_end_code`, MJPEG with 4
  KiB of zeros, both ending in an empty LAST buffer (the header buffer keeps the queued count above
  the LAST threshold): 60 of 60, MPEG-4 720p 65.3 dB, with B-frames 66.3, 1080p 59.0 (min 51.6, IDCT
  drift within the 12-frame GOP, spread over the picture).
- One 1080p MPEG-4 run of seven delivered 59 frames, misaligned; not reproduced since.
- H.263: the stream reaches the decoder and `gxl_h263` raises no interrupt, with or without
  `MP4_PIC_WH` and `MP4_SYS_RATE` as the vendor writes them; `gxl_mpeg4_5` under its name neither.
  Amlogic feeds FLV1 to `VIDEO_DEC_FORMAT_H263`; dropped from the table.
- ffmpeg's `mpeg4_v4l2m2m`: 3 frames of 60, as for every codec; it has no MJPEG wrapper.
- The matrix on this module: H.264, HEVC and VP9 bit-exact at 720p, 1080p and 4K except one HEVC
  720p run, aborted on "Unrecognized dec_status: 00000000" right after the 4K H.264 decode; ten more
  on this module and ten on the installed one, all bit-exact. MPEG-2 66.4 and 67.5 dB.
- H.263 is not a hardware feature: the S905X datasheet's decoder list (rev 0.2, the GXL family; no
  S905L3 datasheet is public) has MPEG-4 ASP, VC-1, AVS, RealVideo and MJPEG, no H.263 or Sorenson.
  Kodi's Amlogic decoder refuses H.263 ("amcodec can't handle h263").

## 2026-10-12 — VC-1

- Protocol from Amlogic's legacy `vvc1.c`: 4 buffers, canvases in `AV_SCRATCH_0-3`, profile in
  `AV_SCRATCH_4` (1 Advanced, 0 Simple/Main), done in `AV_SCRATCH_9`, recycle `~BIT(i)` into
  `AV_SCRATCH_8`, stream offset in `AV_SCRATCH_C`, workspace less `0x01f00000` in `AV_SCRATCH_F`.
  The MPEG-4 pattern otherwise: source change from start, canvases and a microcode reboot in resume.
- Framing as Kodi's AMLCodec: the codec_data's first byte dropped, `00 00 01 0D` before each frame.
- GStreamer 1.26.2 (trixie) registers `v4l2vc1dec` and cannot configure it: "Invalid caps", no
  `video/x-wmv` case in `gst_v4l2_object_get_caps_info()`. Added in 1.26.6. Tested with trixie's
  1.26.2 `gst-plugins-good` v4l2 plugin built on the box with the 1.26.6 change, loaded from a
  private `GST_PLUGIN_SYSTEM_PATH_1_0`. Its sink caps are `WVC1` only, so Simple/Main (WMV3, Annex
  L) has no client here and is left out. ffmpeg's `vc1_v4l2m2m`: no frames.
- Factory `gxl_vc1`, Matroska remuxes of samples.ffmpeg.org clips: every picture bit-exact against
  ffmpeg — 1280x720p60 P-only 101 of 120, 1440x576 IBPB 44 of 50, 1920x1080i IBBP 29 of 60.
- Missing: skipped frames (1- and 6-byte packets; the microcode bumps its repeat count and outputs
  nothing), and the last two pictures. Neither `00 00 01 0A`, nor zeros to 4 KiB, nor skipped
  frames, nor the sequence header replayed after the stream releases them; Amlogic's newer V4L2
  driver displays its last reference itself, a protocol this microcode lacks.
- Not causes, ruled out: the VIFIFO level (`MEM_FIFO_CNT` 2, level 8, as the vendor writes), a
  deferred recycle (B-frames identical either way).
- A wrong turn: 1440x576 looked like drift from frame 1. `filesink` had written the decoder's padded
  1472-byte rows; through `videoconvert` the same output is bit-exact. Compare packed frames only.
- MPEG-2 at 720x576 hangs with no picture, with and without B-frames, and on a fresh build of
  `0001`-`0006` alone; 1280x720 with B-frames decodes. One run of seven on the baseline completed.
- `patches/gst-plugins-good/README.md` run verbatim: the plugin diverted in place, `playbin` picks
  `v4l2vc1dec`, 1440x576 44 of 44 bit-exact, H.264 still bit-exact; removal leaves the package as
  `dpkg -V` expects.

## 2026-10-12 — MPEG-2 at 720x576

- Two hangs, both intermittent. Most runs: 2 inputs queued, no picture, and "VIFIFO usage
  (1718652275) > VIFIFO size". The multi codec resets the VLD between pictures; until it restores
  RP, `VLD_MEM_VIFIFO_LEVEL` reads as the WP address (`0x666f....`). The parser took the FIFO for
  full and refused input for good. Clamped in `vdec_1_vififo_level()` (`0011`).
- A run that started decoded all 50 pictures and ended through the codec's own EOS path; the "2 bufs
  remain" count was the header buffers, not a stall.
- With `0011`: 720x576 10 of 10 runs complete, 50 of 50 pictures, 62.8 dB worst; 720x576 with
  B-frames, 1280x720 with and without, 1920x1080, five runs each, all complete, 65.5-69.1 dB. H.264
  bit-exact to 4K; MPEG-4, MJPEG, VC-1 unchanged.
- VC-1 720p's picture count varies 98-101 run to run, on this module and the installed one alike;
  every picture bit-exact. GStreamer drops some around the skipped frames.
