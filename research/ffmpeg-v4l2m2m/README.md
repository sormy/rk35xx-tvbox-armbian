# ffmpeg 9 with V4L2 mem2mem on the H96 Max M20

ffmpeg 9.0.2 with five patches drives every hardware decoder and both encoders on the S905L3 the way
GStreamer does. Needs `meson-vdec-gxlx2` with `patches/meson-codecs/` `0014` and `0015`. Not
shipped: a static build into `/opt/ffmpeg-9`, beside Debian's ffmpeg.

## Build

On the box, as root, about 26 minutes:

```bash
sh research/ffmpeg-v4l2m2m/build.sh
```

## Patches

| Patch  | Fixes                                                              |
| ------ | ------------------------------------------------------------------ |
| `0001` | raw elementary streams: unstamped packets came back all at pts 0   |
| `0002` | MPEG-1/2, MPEG-4 and VC-1 `extradata` sent ahead of the first one  |
| `0003` | `mjpeg_v4l2m2m`, which ffmpeg lacks                                |
| `0004` | encoders fill `extradata` for Matroska and MP4                     |
| `0005` | the drain waits for a CAPTURE buffer before it reports end of file |

`0001`: ffmpeg sends a packet without pts as 0, and the constant-rate output keeps 3 frames of 60.

`0004`: the encoders join SPS/PPS (VPS/SPS/PPS) to the first frame and take no `HEADER_MODE`; the
patch encodes one black frame at init, keeps its parameter sets as `extradata`, and forces the first
real frame to a key frame.

`0005`: ffmpeg ends a drain once no CAPTURE buffer is in the driver; MJPEG's four-buffer pool hits
that between frames, and a 1080p decode lost frames without it.

## Results

✅ measured 2026-10-13: clips from Debian's software encoders, compared frame by frame against
Debian's software decode.

| Codec       | Container          | Result                         |
| ----------- | ------------------ | ------------------------------ |
| H.264       | MKV 1080p, MP4 4K  | ✅ bit-exact, every frame      |
| HEVC        | MKV 1080p, MP4 4K  | ✅ bit-exact, every frame      |
| VP9         | WebM 1080p, MKV 4K | ✅ bit-exact, every frame      |
| MPEG-2      | MKV 1080p, MP4 576 | ✅ every frame, 66.7-68.6 dB   |
| MPEG-4      | AVI, MP4 720p      | ✅ every frame, 51.7-58.6 dB   |
| MJPEG       | AVI 720p, MKV 1080 | ✅ every frame, 72.2-73.5 dB   |
| VC-1        | MKV 576, 720p      | ✅ bit-exact, as GStreamer     |
| H.264 enc.  | MKV, MP4, raw      | ✅ 60 of 60, 45.8-52.8 dB PSNR |
| HEVC enc.   | MKV, MP4, raw      | ✅ 60 of 60, 44.9-51.1 dB PSNR |
| Raw streams | `.264` `.m2v` etc. | ✅ as from a container         |

Inexact decodes differ from the software decoder by IDCT rounding. VC-1 misses the frames the stream
marks skipped, as GStreamer does.

## Not needed

| Tried                                   | Why dropped                           |
| --------------------------------------- | ------------------------------------- |
| driver: no `EPOLLERR` until LAST        | no frame count changed once `0015` in |
| ffmpeg: copy frames out of a short pool | `0005` alone keeps MJPEG whole        |
| Raspberry Pi's fork, `7.1.5+rpt2`       | 4K HEVC, MPEG-4, VC-1 fail; no MJPEG  |
| `-num_capture_buffers 8` for 4K         | the driver caps it: `0014`            |
