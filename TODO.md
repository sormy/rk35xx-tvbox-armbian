# TODO

Small items live here. An item that needs its own page gets one in `docs/todo/`, listed below.

## Open

- [ ] **H96 Max M20: VC-1 needs GStreamer 1.26.6.** 1.26.2, trixie's, maps no caps to
      `V4L2_PIX_FMT_VC1_ANNEX_G`: `v4l2vc1dec` registers and fails "Invalid caps". By hand until
      trixie moves: `patches/gst-plugins-good/README.md`. TVBian replaces no Debian package, so it
      waits for trixie or upstream.

- [ ] **H96 Max M20: ffmpeg's `*_v4l2m2m`.** Every codec works on 9.0.2 with
      `research/ffmpeg-v4l2m2m/`'s patches; Debian's 7.1.5 still fails MPEG-4, VC-1, raw streams and
      encode to Matroska. Open: send the patches to ffmpeg, or ship the build.

- [ ] **H96 Max M20: the decoder leaves CAPTURE buffers active on STREAMOFF.** Four `WARN`s, buffers
      0-13, all from Fuseamp's `fuseamp-flips` and `fuseamp-quality`; ffmpeg stopped early on H.264,
      HEVC 8- and 10-bit, VP9 to 4K does not reproduce it. Next: that client's ioctl sequence around
      the stop.

- [ ] **H96 Max M20: Wi-Fi stays on 2.4 GHz.** Not mt76: both bands join, and `0013` reloads the
      firmware for a switch between the access point's two BSSIDs. The box's network pins `bssid=`
      to the 2.4 GHz radio, and with no `bgscan` nothing re-picks once joined. Next: the SSID alone
      plus `bgscan`, then time a band switch, which `0013` costs about 6 s.

- [ ] **H96 Max M20: GStreamer's `v4l2h264enc` crashes.** `videotestsrc ! v4l2h264enc` dies with
      `SIGSEGV` in `gst_memory_unmap`, in the plugin's input pool; `v4l2h265enc` and ffmpeg's
      `h264_v4l2m2m` encode.

- [ ] **RK35xx boards: size CMA for 4K at 60 fps.** The M20 needed 768 MiB, not 384, to decode 4K at
      60 fps and copy it into render buffers. The H313's factory tree reserves 8 MiB, its video
      engines behind an IOMMU; ours is `cma=256M`. Measure `CmaFree` during 4K decode on each board.
- [ ] **H96 Max M20: sluggish.** Idle, zram and CMA sat unused for 8 h 26 min, 2026-10-20, which
      says nothing about load. Play 4K and watch `vmstat 1` and `CmaFree` together.

- [ ] **H96 Max M20: 4K at 60 fps on screen, through a COMPOSE selection.** `meson-codecs` `0017`
      decodes HEVC and VP9 to a half-size CAPTURE when asked; not yet watched at 60 Hz. Then:
      whether the payload sets `capture_max_height`, and whether H.264's core can scale.

- [ ] **RK3518 boards: revisit display and GPU against the H96 Max M20.** Same Mali-450 and the same
      BOE 2256x1504 panel: the M20 runs it native at 60 Hz with glmark2 **64**, where the RK3528
      boards score 41 at 1080p and 2048x1152 and cannot clock the native mode
      (`docs/todo/rk35xx-hdmi-modes.md`). Record each board's GPU clock and devfreq governor, then
      rerun glmark2 on the same panel.

- [ ] **TVBian: write `tvb-firstlogin`.** Designed in `docs/todo/tvb-linux-rootfs.md`, "First
      login"; not built, so a fresh image stops at root, `1234`, expired. Its Wi-Fi step is the
      M20's only network on a fresh image.
- [ ] **Retire the overlay, once the weekly build publishes.** No box runs it since 2026-10-20.
      Going: `payload.list`, `rk35xx-update`, `rk35xx-deploy`, `build-image.sh`, the
      `fetch-*-src.sh` scripts, `firmware/common/`'s overlay-only files (`mac-pin`,
      `vendor-storage`, `firstboot`, `boardname`, `dtb-persist`, `platform-install`, the kernel
      hooks), every `board.conf`'s `BOARD_DKMS_FETCH` and hooks, and the docs and sections
      describing them, `docs/apt-upgrade.md` among them. `docs/migrate.md` stays: the repo is
      public, and a box elsewhere may still run the overlay.
- [ ] **Check the `ttyFIQ0` login on a serial header.** Every Rockchip board's console is `ttyFIQ0`,
      seen in `/proc/consoles` with its getty running; never on a cable.
- [ ] **Name repo folders by what they hold.** `firmware/` holds boards, not only blobs, and clashes
      with `/lib/firmware`: `firmware/<board>/` to `boards/<board>/`, `firmware/common/<chip>/` to
      `chips/<chip>/`. Patches move beside their owner: kernel topics to `kernel/patches/<topic>/`,
      host tools' beside the tool. Repo paths only; no box sees them, so it waits for a quiet
      moment.

- [ ] **Name every board by its product, with the silkscreen as a separate field.** `board-name`
      mixes the two in one string.
  - `board.conf` gets the product name and the PCB silkscreen as two settings; `board-name` derives
    from them the same way on every board.
  - A key rename is a package rename, `tvb-<board>`, and a hostname change.

- [ ] **`tvb-install`, a first real install.** `firmware/common/tvb-install` has reached its prompt
      on the H313, never past it: the H313 from its SD to the eMMC, keeping `DVKR`/`SSKR`; the M20
      image from a stick to the eMMC, then back from the eMMC to a stick. Together they test phases
      4 and 5.
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
- [ ] **Wake the H96 Max M20 from `s2idle` on its Bluetooth remote**, its only remote. The SDIO
      interrupt carries the wake but `meson-gx-mmc` never arms it as a wake source, and `btmtksdio`
      keeps the card powered only in runtime suspend. The other route is the combo chip's host-wake
      GPIO 100, which needs the chip-side pin for the low-power command. Until one works, the M20's
      keys ignore suspend and poweroff.

## Bigger todos

| File                                    | Open question                                 |
| --------------------------------------- | --------------------------------------------- |
| `docs/todo/media-stick.md`              | the universal media stick                     |
| `docs/todo/rk35xx-boot-log.md`          | boot log cleanup                              |
| `docs/todo/rk35xx-hdmi-modes.md`        | RK3528 unclockable modes, slow EDID probes    |
| `docs/todo/rk35xx-kernel-patches.md`    | Armbian's vendor patches Rockchip never took  |
| `docs/todo/rk35xx-mac-pinning.md`       | MAC pinning below userspace                   |
| `docs/todo/rk35xx-optee-widevine.md`    | OP-TEE, and Widevine after it                 |
| `docs/todo/rk35xx-remote-keymaps.md`    | keymap correctness per board and transport    |
| `docs/todo/rk35xx-sd-uhs-warm-reset.md` | `dwmmc` first init after a warm reset         |
| `docs/todo/rk35xx-uboot-usb.md`         | USB in our U-Boot                             |
| `docs/todo/tvb-linux.md`                | TVBian: our kernel and images on plain Debian |
| `docs/todo/tvb-linux-rootfs.md`         | TVBian's minimal rootfs and first login       |
| `docs/todo/tvb-linux-build.md`          | TVBian's weekly build, hosts, caches          |
