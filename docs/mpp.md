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

Build **out of tree**: aiming cmake at `~/mpp/build` deletes MPP's own cmake helpers, and every
later configure dies on `Unknown CMake command "merge_objects"`. For ffmpeg `--enable-rkmpp`,
`sudo make -C ~/mpp-build install` puts the library in `/usr/local/lib`.

## Gate — does MPP recognise the SoC?

```sh
mpp_debug=0x10 mpi_enc_test -t 7 -w 176 -h 144 -n 1 -o /dev/null 2>&1 | head -3
```

`match chip name: …` passes. `use default chip info` means the device tree's root `compatible` names
nothing MPP knows; every encode then dies at `could not found coding type` and decode quietly runs
on the CPU. Fix the tree, not MPP's table.

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
- **MJPEG decode needs explicit `-w`/`-h`**, or it dies at `mpp_buffer_get … size 0` and reads like
  broken hardware.
- **Always `-pix_fmt yuv420p`** — otherwise ffmpeg hands you VP9 profile 1, which the hardware
  rejects and then spins forever. Hence `timeout` on every run.
- H.264 encode returned empty frames before `rockchip-linux/mpp` commit `905020444` (2026-08-10).
