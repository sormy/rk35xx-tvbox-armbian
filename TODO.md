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

- [ ] **RK3518 boards: revisit the GPU against the H96 Max M20.** Same Mali-450 and the same BOE
      2256x1504 panel: the M20 scores glmark2 **64** at it native; the RK3528 boards scored 41 at
      1080p and 2048x1152, before today's vendor kernel clocked the native mode. Record each board's
      GPU clock and devfreq governor, then rerun glmark2 on the same panel.

- [ ] **An AI review on every pull request, against `AGENTS.md`.** A fork PR runs without our
      secrets, so a GitHub App fits: CodeRabbit's open-source plan, free for a public repo and
      rate-limited per developer, pointed at `AGENTS.md`. Gemini Code Assist's free GitHub app is
      reported shut down in July 2026. To think about: the Claude Code action, automatic on the
      maintainer's own PRs and on anyone else's only when the maintainer invokes it by comment,
      since a comment from a maintainer runs with the repo's token and a fork PR does not. ❓
      CodeRabbit's current limits, and the file it reads guidelines from.

- [ ] **Check the `ttyFIQ0` login on a serial header.** Every Rockchip board's console is `ttyFIQ0`,
      seen in `/proc/consoles` with its getty running; never on a cable.
- [ ] **The repo restructure.** Folders named for what they hold, patches beside their owner, tools
      under `tools/`, docs current or in `research/`: `docs/todo/repo-layout.md`.

- [ ] **`tvb-install`, a first real install.** `firmware/common/tvb-install` has reached its prompt
      on the H313, never past it: the H313 from its SD to the eMMC, keeping `DVKR`/`SSKR`; the M20
      image from a stick to the eMMC, then back from the eMMC to a stick. Together they test phases
      4 and 5.
- [ ] **Keep an Amlogic board's Ethernet address, as `LAN_MAC` is kept on Rockchip.** It is the
      unifykey `mac` slot, encrypted, so only the vendor U-Boot reads it (`keyman read mac`); the
      stock env hands it to Android as `mac=`. Our `aml_autoscript` runs in that U-Boot: read it,
      then `env export -t` `ethaddr` to fixed RAM for `boot.scr` to `env import` in the chained
      U-Boot, which sets `local-mac-address`. ❓ `env export` in this U-Boot; a RAM address neither
      relocates over.
- [ ] **H96 Max M20: unbrick from the mask ROM.** Needed only once the eMMC's bootloader is gone;
      the factory U-Boot's burning gadget covers every other path. A USB-boot BL2 from
      `stock/h96max-m20/loader-stages/bl2.sign` and `acs.bin` (format v3), repacked with `gxlimg`
      and committed beside the board as Rockchip's `maskrom_loader.bin` is; then `amlcmd` loads it
      and U-Boot, which takes bulk writes and BL2's USB stage — `pyamlboot` has both. Safe to try:
      `amlcmd set_usb_boot 2` enters the ROM, a power cut leaves it.
- [ ] **Close the known gaps** listed in `patches/mt76-mt7668/README.md` and
      `docs/h96max-m20/board.md`.
- [ ] **Wake the H96 Max M20 from `s2idle` on its Bluetooth remote**, its only remote. The SDIO
      interrupt carries the wake but `meson-gx-mmc` never arms it as a wake source, and `btmtksdio`
      keeps the card powered only in runtime suspend. The other route is the combo chip's host-wake
      GPIO 100, which needs the chip-side pin for the low-power command. Until one works, the M20's
      keys ignore suspend and poweroff.
- [ ] **No kernel self-tests in meson64.** 146 of its 4433 modules are KUnit and test modules, from
      Armbian's config: off in `kernel/meson64.fragment` (`CONFIG_KUNIT`), then a boot on the M20.
      The rest of its breadth stays: USB Wi-Fi, tuners and cameras are why a box is general.
- [ ] **Low priority: `tvb-firstlogin`, the first-login wizard.** Until then, `docs/first-login.md`
      gives the commands. Runs once, from `/etc/profile.d/`, at root's first interactive login; Esc
      skips a step; `/var/lib/tvb/firstlogin.done` marks it finished, so an interrupted run starts
      again:
  - a user: `adduser`, added to `sudo`;
  - the timezone: `timedatectl list-timezones` through `fzf`;
  - the locale: `SUPPORTED`'s UTF-8 lines through `fzf`, then `locale-gen`;
  - Wi-Fi, where a Wi-Fi device exists: `nmcli device wifi list` through `fzf`, then
    `nmcli --ask device wifi connect`.
- [ ] **RK3528 boards: a 4K display on the R69 and the H313.** Every RK3528 `board.dts` sets
      `esmart_lb_mode = [02]`, a 4K line buffer for Esmart0, where the factory's `[03]` corrupts the
      right third of a 4K frame; ✅ on the 3518D only. Check `3840x2160p60` full-screen with no
      fringe on the right, then that a 1080p display still comes up clean.
- [ ] **A USB keyboard's keymap on `tty1`:** `console-setup` in the image and a README line, or US
      only.
- [ ] **BTF:** dropped with debug info by `CONFIG_DEBUG_INFO_NONE`, or kept for BPF tools at the
      cost of runner disk.
- [ ] **Gate a kernel that moved** on the validation script passing on one box of its family, or
      keep publishing it automatically.
- [ ] **Sealed TVBian:** image-based A/B updates, an option for any flavour, plain or Kodi. Levels:
      a read-only root, a volatile root, then A/B with `systemd-sysupdate`, two roots plus a data
      partition and a fallback at boot.

## Bigger todos

| File                                    | Open question                                  |
| --------------------------------------- | ---------------------------------------------- |
| `docs/todo/media-stick.md`              | the universal media stick                      |
| `docs/todo/rk35xx-boot-log.md`          | boot log cleanup                               |
| `docs/todo/rk35xx-sd-uhs-warm-reset.md` | `dwmmc` first init after a warm reset          |
| `docs/todo/rk35xx-uboot-usb.md`         | USB in our U-Boot                              |
| `docs/todo/website.md`                  | tvbian.com: one page on GitHub Pages           |
| `docs/todo/repo-layout.md`              | folders, patches, tools and docs, regrouped    |
| `docs/todo/tanix-h313.md`               | first Allwinner board; the bring-up docs' test |
