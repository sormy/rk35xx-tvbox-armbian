# Amlogic video codec firmware

`package.list` here builds `tvb-firmware-amlogic`. `vdec/` and `venc/` install under
`/usr/lib/firmware/updates/meson/`, ahead of Debian's; `gxlx2/` holds GXLX2's builds of names Debian
builds for other chips, which only a GXLX2 board links into `/usr/lib/tvb/firmware`.

M20 stock means the entry of that name in the M20's factory `video_ucode.bin`, version
`v0.2.287de0d` of 2021-01-27, in `stock/h96max-m20/firmware/video/`: per blob a 512-byte `EDOC`
header, `data_size` at offset 200, then the payload.

| File                         | Origin                                    |
| ---------------------------- | ----------------------------------------- |
| `vdec/gxl_h264.bin`          | M20 stock, repacked: pages 0-3, 4 2 6 3 5 |
| `vdec/gxl_mpeg4_5.bin`       | M20 stock `gxl_xvid.bin`, identical       |
| `vdec/gxl_mpeg12_multi.bin`  | M20 stock, zero-padded to 16 KiB          |
| `vdec/gxl_vc1.bin`           | M20 stock, identical                      |
| `gxlx2/g12a_hevc_mmu.bin`    | M20 stock, identical                      |
| `gxlx2/g12a_vp9.bin`         | M20 stock, identical                      |
| `gxlx2/gxl_mjpeg.bin`        | M20 stock, identical                      |
| `venc/gxl_h264_enc.bin`      | M20 stock, identical                      |
| `venc/ga_h264_enc_cabac.bin` | M20 stock `g12a_h264_enc_cabac.bin`       |
| `venc/monet.bin`             | Chips&Media, via StarFive's SDK           |

The repack: mainline's `codec_h264` loads 16 KiB of main code and then exactly 20 KiB of sections
(`SIZE_EXT_FW`). The factory's newer build carries 12 KiB, having dropped the copies of main pages 2
and 3 that the older layout keeps among them, so the copies go back in.

`monet.bin` is Chips&Media's WAVE420L firmware as `meson-sm1-codecs` pins it, md5
`dbfaf48e103e1bf7f1101b49c5e3bbde`, under `venc/LICENSE.monet.txt`. The factory image has no such
file: its WAVE420L build sits inside the vendor's `libOmxVideo.so`, which hands it to `vpu.ko`.

Why not the factory's: it is older. Asked with `GET_FW_VERSION` on the M20, ours reports revision
196485, the factory's 106664, cut from `.rodata` at the pointer `Wave4VpuInit` passes, 141440 bytes.
Both encode.

`vdec/LICENSE.amlogic_vdec` is linux-firmware's licence for Amlogic's decoder microcode.
