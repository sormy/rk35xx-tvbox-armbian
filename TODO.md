# TODO

Small items live here. An item that needs its own page gets one in `docs/todo/`, listed below.

## Open

- [ ] **Rename the installed prefix `rk35xx-` to `tvb-`.** It is SoC-specific and the repo now
      carries an Amlogic board. Keep a prefix — the files share `/usr/local/sbin`, `udev`, `systemd`
      and `modprobe.d` with the distro, and the updater prunes by it.
  - `BOARD_PREFIX` becomes one constant in `firmware/common/`, not a per-board setting.
  - Rockchip-only pieces keep a Rockchip name: `rockchip-pwm-remotectl-rk35xx`, vendor storage, VPU.
  - A deployed box migrates through its old `rk35xx-update --pull`: install `tvb-*`, disable the old
    units, delete `rk35xx-*`, move the known-good DTB out of `/usr/local/share/rk35xx/`.
  - Rename the repo to `tvbox-armbian` and the `--pull` URL with it.
  - Test on a box on the old layout: one update, one reboot, one kernel reinstall with the DTB
    intact.

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
- [ ] **Make `rk35xx-bt` verify mgmt registration, not just the sysfs node.** A restart of it
      orphans bluez about half the time — sysfs `hci0` present and raw HCI up, but `btmgmt info`
      reports `Index list with 0 items`, so no controller for bluez — while the script exits 0
      because `[ -e /sys/class/bluetooth/hci0 ]` holds either way. Poll for the mgmt index and
      re-attach when it never appears. Recovery until then: `systemctl restart rk35xx-bt` (2/2,
      worklog §26).
- [ ] **Clean the live M20:** drop `mt7668_patch_e1_hdr.bin`, `TxPwrLimit_MT76x8.dat` and
      `BT_RAM_CODE_MT7668_1_1_hdr.bin` from `/lib/firmware/mediatek`, which nothing reads.
- [ ] **Settle the R69's AV jack.** `docs/r69/worklog.md` §8 lists `analog AV audio` among the
      things verified over SSH; `docs/h96max-h313/worklog.md` says AV audio and composite video are
      untested on both boards. The README row keeps 🟡 until they agree — no doc claims composite
      video on any board.

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
