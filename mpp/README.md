# MPP — the library that actually reaches the VPU

Rockchip's **Media Process Platform** (`librockchip_mpp`) is a userspace library, not a kernel
driver and not part of ffmpeg. The vendor kernel exposes the video engines only as
`/dev/mpp_service` — MPP's own ABI, not V4L2 M2M — so everything that wants hardware video (ffmpeg
built `--enable-rkmpp`, GStreamer, Kodi, the prebuilt stacks) links against MPP to get there. Debian
doesn't ship it; you build it.

**The image deliberately doesn't carry any of this** — a compiled ffmpeg/MPP stack is exactly the
"big compiled userspace" that would make this repo expensive to maintain. What the image _does_ ship
is the two things a stack can't fix for itself: the DTB that lets MPP identify the SoC, and the udev
rule that lets a non-root process open the VPU. See [`../docs/codec.md`](../docs/codec.md).

This folder holds one patch, because it fixes a bug you would otherwise waste a day on.

## First: MPP has to recognise the SoC

Everything here depends on it. MPP picks its codec table by matching the **root `compatible` in the
device tree**; when it recognises nothing it falls back to a generic profile describing encoders
this silicon doesn't have, and every encode fails with `could not found coding type` while decode
quietly runs on the CPU. No error names the real cause.

The name MPP matches for this family is **`rockchip,rk3528a`**. Both boards here ship a tree
carrying it — the R69 from the factory, the H96 Max via a one-line graft
([why](../docs/h96max/dtb.md)). One command tells you which entry it actually matched:

```sh
mpp_debug=0x10 mpi_enc_test -t 7 -w 176 -h 144 -n 1 -o /dev/null 2>&1 | head -3
```

`match chip name: rk3528a` is what you want. `use default chip info` means the device tree is the
problem, and nothing below will work until that is fixed — patching MPP's SoC table to paper over it
is not worth doing.

## `h264e-vepu540c-status.patch` — makes H.264 encoding work

Stock MPP cannot encode H.264 on this silicon. Every frame comes back empty:

```
hal_h264e_vepu540c_status_check enc not done hw_status: 0x00000000
chn 0 encoded frame 29   size 0
```

It reads like dead hardware. It isn't — the `rkvenc` interrupt fires **exactly once per submitted
frame**, so the encoder accepts every job and completes it. The bug is plumbing:
`hal_h264e_vepu540c_status_check()` tests `reg_ctl.common.int_sta.enc_done_sta`, but the H.264 path
only ever _writes_ the control block — its single `MPP_DEV_REG_RD` covers `reg_st`. Nothing reads
the hardware status word back, so the check always sees the zero MPP itself wrote. The H.265 HAL, on
the very same `vepu540c` block, reads it explicitly from `VEPU540C_REG_BASE_HW_STATUS` — which is
the whole reason HEVC works and H.264 doesn't.

The patch adds that one read-back, 12 lines, mirroring the H.265 path.

**This is not board-specific.** Any SoC whose H.264 encoding goes through `hal_h264e_vepu540c` —
RK3528, RK3562 and relatives — should hit it.

## Build MPP, with the patch

```sh
sudo apt install -y cmake build-essential git      # a bare Armbian has git and gcc, but no g++
git clone --depth 1 https://github.com/rockchip-linux/mpp ~/mpp
git -C ~/mpp apply /path/to/this/repo/mpp/h264e-vepu540c-status.patch
cmake -S ~/mpp -B ~/mpp-build -DCMAKE_BUILD_TYPE=Release && nice make -C ~/mpp-build -j4
export PATH="$HOME/mpp-build/test:$PATH"
```

> **Build out of tree.** MPP keeps its own cmake helpers in `mpp/build/`, so aiming cmake's output
> there deletes `merge_objects.cmake` and every later configure dies on
> `Unknown CMake command "merge_objects"` — with the evidence already gone. Use `~/mpp-build`.

`sudo make -C ~/mpp-build install` puts `librockchip_mpp.so` in `/usr/local/lib` if you then want to
build ffmpeg `--enable-rkmpp` against it.

## Check it worked

```sh
mpi_enc_test -t 7 -w 1920 -h 1080 -n 30 -o /tmp/h264.bin   # -t 7 = H.264
ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/h264.bin
```

Before: `size 0` and a ~40-byte file. After: a real bitstream, `h264,1920,1080`. Measured with the
patch, both boards, `ffprobe`-verified at every frame size — and HEVC unaffected:

| H.264 encode |  720p | 1080p |   4K |  8K |
| ------------ | ----: | ----: | ---: | --: |
| R69          | 116.3 |  55.0 | 14.4 | 3.6 |
| H96 Max      | 115.3 |  54.9 | 14.4 | 3.6 |

## Upstream status

**Not upstream as of 2026-08-09.** `rockchip-linux/mpp` `develop` has recent `vepu540c`/RK3528
register work but nothing that repairs this; `nyanmisaka/mpp` — what the prebuilt rkmpp ffmpeg
builds use — carries the same commits; and no MPP issue describes the failure. The patch applies
cleanly to a pristine `develop` checkout.
