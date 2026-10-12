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
