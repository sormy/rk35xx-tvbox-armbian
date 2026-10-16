# TODO

Small items live here. An item that needs its own page gets one in `docs/todo/`, listed below.

## Open

- [ ] **H96 Max M20: the BOE 2256x1504 panel blinks on about one boot in three.** Same registers on
      blinking and steady boots; the transmitter sees no event; a blank/unblank re-lock stops it.
      The PLL is programmed as the factory's; from a Mac the panel never blinks, so the box's output
      is the weak side. Parked; candidates: the HDMI PHY drive at this pixel clock, then a pixel
      clock the PLL makes without a fraction. The worklog has what was ruled out.

- [ ] **H96 Max M20: VC-1 needs GStreamer 1.26.6.** 1.26.2, trixie's, maps no caps to
      `V4L2_PIX_FMT_VC1_ANNEX_G`: `v4l2vc1dec` registers and fails "Invalid caps". By hand until
      trixie moves: `patches/gst-plugins-good/README.md`. Shipping it would mean a diverted system
      plugin in the payload.

- [ ] **H96 Max M20: ffmpeg's `*_v4l2m2m`.** Every codec works on 9.0.2 with
      `research/ffmpeg-v4l2m2m/`'s five patches; Debian's 7.1.5 still fails MPEG-4, VC-1, raw
      streams and encode to Matroska. Open: send the patches to ffmpeg, or ship the build.

- [ ] **H96 Max M20: the decoder leaves CAPTURE buffers active on STREAMOFF.** Four `WARN`s, buffers
      0-13, all from Fuseamp's `fuseamp-flips` and `fuseamp-quality`; ffmpeg stopped early on H.264,
      HEVC 8- and 10-bit, VP9 to 4K does not reproduce it. Next: that client's ioctl sequence around
      the stop.

- [ ] **H96 Max M20: Wi-Fi on a fresh image.** The box has no Ethernet, and Armbian's netplan gives
      `wl*` no DHCP. Check whether the first-boot wizard's Wi-Fi setup gets an address; if not, ship
      a `wlan0` network file in the payload.

- [ ] **RK35xx boards: size CMA for 4K at 60 fps.** The M20 needed 768 MiB, not 384, to decode 4K at
      60 fps and copy it into render buffers. Measure each board's CMA peak on that load.

- [ ] **H96 Max M20: 4K at 60 fps, through a downscaled decoder copy.** The video plane cannot read
      3840x2160 NV12 at 60 Hz. The HEVC core can write a half or quarter size copy beside the
      full-size references (Amlogic's `double_write_mode`), which `codec_hevc` already does at 1:1
      for 10-bit: add the ratio as a decoder control, report the scaled CAPTURE size.

- [ ] **RK3518 boards: revisit display and GPU against the H96 Max M20.** Same Mali-450 and the same
      BOE 2256x1504 panel: the M20 runs it native at 60 Hz with glmark2 **64**, where the RK3528
      boards score 41 at 1080p and 2048x1152 and cannot clock the native mode
      (`docs/todo/rk35xx-hdmi-modes.md`). Record each board's GPU clock and devfreq governor, then
      rerun glmark2 on the same panel.

- [ ] **Rename the installed prefix `rk35xx-` to `tvb-`.** Design: `docs/todo/tvb-namespace.md`.

- [ ] **Name every board by its product, with the silkscreen as a separate field.** `board-name`
      mixes the two in one string.
  - `board.conf` gets the product name and the PCB silkscreen as two settings; `board-name` derives
    from them the same way on every board.
  - A key rename moves installed paths and the hostname: it rides the prefix rename's migration.

- [ ] **Install an Amlogic box to eMMC from its booted stick.** `scripts/aml-emmc-install` run on
      the box against the eMMC's block device, with the backup on the stick; same regions, same key
      check. `armbian-install` cannot: it zeroes 0-10 MiB, partitions from 16 MiB over `reserved`,
      and writes the donor board's `u-boot.bin` at sector 0.
- [ ] **Install an Amlogic box to eMMC: single boot, as CoreELEC does.** Android goes, `cache` goes,
      `env` moves down; only the bootloader areas are lost. One image per board, written by
      `amlcmd restore`, which never writes a hole:
  - board data burnt in: the bootloader, `reserved`'s `MPT` and both multi-DTB copies with `cache`
    shrunk, a preset `env` at its new offset, `u-boot.ext` raw in the 4-36 MiB gap, then the rootfs;
  - the one hole: `reserved`'s key window, this unit's serial and MAC;
  - the `MPT` and DTB checksums from ampart's source, reproduced offline against the stock copies
    first;
  - testable on the eMMC only, with serial attached - a U-Boot that stops before its prompt needs
    the mask ROM, which is ❓. Staged: rehearse a no-op `restore` of `reserved`; rewrite DTB copy 1
    alone with a neutral change and our checksum, leaving copy 2 stock - U-Boot's `total valid 2`
    proves the checksum, and the layout does not move; only then the real layout.
  - the vendor U-Boot loads `u-boot.ext` with `amlmmc read`: it reads the eMMC as `PART_TYPE_AML`,
    not our MBR;
  - `restore` refuses a bootloader that differs from the box's, and skips an identical one.
  - the installer insists on a full backup of this box - the only way back to Android - and checks
    it by comparing the box's key window with the backup's; the image itself never takes data from
    it.
- [ ] **Keep an Amlogic board's Ethernet address, as `LAN_MAC` is kept on Rockchip.** It is the
      unifykey `mac` slot, encrypted, so only the vendor U-Boot reads it (`keyman read mac`); the
      stock env hands it to Android as `mac=`. Our `aml_autoscript` runs in that U-Boot: read it,
      then `env export -t` `ethaddr` to fixed RAM for `boot.scr` to `env import` in the chained
      U-Boot, which sets `local-mac-address`. ❓ `env export` in this U-Boot; a RAM address neither
      relocates over.
- [ ] **Close the known gaps** listed in `patches/mt76-mt7668/README.md` and
      `docs/h96max-m20/board.md`.
- [ ] **Drop `rk35xx-mac-pin` wherever the drivers already give each interface its own address.**
      The H96 Max M20 needs no pinning: mt76 reads the Wi-Fi address from the chip's eFUSE. Per
      board, boot without the service twice and compare every interface's address; remove it, its
      unit and its payload lines where all are stable, and close `docs/todo/rk35xx-mac-pinning.md`
      if none is left.
- [ ] **Keep the vendor console on the R69 and the H96 Max H313, as the 3518D does.** Why it is
      safe: `docs/h96max-3518d/dtb.md`, "Console: this board keeps the vendor's".
  - Drop the `board.patch` hunks that enable uart0 as `ttyS0`, disable `fiq-debugger` and remove
    `chosen`; set `BOARD_SERIALCON` to `console=ttyFIQ0` as the 3518D's `board.conf` does.
  - Update `upstream/r69/header.dts` and `upstream/h96max-h313/header.dts` to list only what
    remains, each board's `dtb.md`, and `upstream/h96max-3518d/header.dts`, which contrasts itself
    with the ZX.
  - Verify on each box: the serial login prompt, and a boot log with no new errors.
- [ ] **Wake the H96 Max M20 from `s2idle` on its Bluetooth remote**, its only remote. The SDIO
      interrupt carries the wake but `meson-gx-mmc` never arms it as a wake source, and `btmtksdio`
      keeps the card powered only in runtime suspend. The other route is the combo chip's host-wake
      GPIO 100, which needs the chip-side pin for the low-power command. Until one works, the M20's
      keys ignore suspend and poweroff.

## Bigger todos

| File                                    | Open question                              |
| --------------------------------------- | ------------------------------------------ |
| `docs/todo/apt-packaging.md`            | the payload as local `.deb`s               |
| `docs/todo/media-stick.md`              | the universal media stick                  |
| `docs/todo/recipes.md`                  | a board composed from recipes              |
| `docs/todo/h96max-issues.md`            | H96 Max open items                         |
| `docs/todo/rk35xx-boot-log.md`          | boot log cleanup                           |
| `docs/todo/rk35xx-hdmi-modes.md`        | RK3528 unclockable modes, slow EDID probes |
| `docs/todo/rk35xx-mac-pinning.md`       | MAC pinning below userspace                |
| `docs/todo/rk35xx-optee-widevine.md`    | OP-TEE, and Widevine after it              |
| `docs/todo/rk35xx-remote-keymaps.md`    | keymap correctness per board and transport |
| `docs/todo/rk35xx-sd-uhs-warm-reset.md` | `dwmmc` first init after a warm reset      |
| `docs/todo/rk35xx-uboot-usb.md`         | USB in our U-Boot                          |
| `docs/todo/tvb-namespace.md`            | the `tvb-` rename and its migration        |
