# Working in this repo

Rules for anyone — human or agent — adding a board or changing this repo. Most have a corpse in
`docs/*/worklog.md` behind them. The procedure itself lives in the docs indexed below.

## What this repo is

Debian with our own kernel, drivers and board packages, not a fork of a distro. Kernel sources and
userspace come from upstream; we carry only what upstream can't know. **Adding a board is data, not
code** — one `boards/<board>/` directory. If a change needs new code per board, the design is wrong.

| Tree               | Holds                                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------- |
| `boards/<board>/`  | `board.conf`, the factory trees, the patches on them and their output, loaders, `package.list` |
| `boards/common/`   | everything shared between boards                                                               |
| `firmware/<chip>/` | a chip's firmware, packaged as `tvb-firmware-<chip>`                                           |
| `docs/<board>/`    | `worklog.md` (history), `dtb.md` (tree changes), `board.md` (usage)                            |
| `stock/<board>/`   | factory evidence: dumps, logs, partition maps                                                  |
| `backup/`          | `<board>-stock.img.xz`, the factory eMMC (gitignored)                                          |
| `patches/<topic>/` | every patch to an upstream's code, one folder per upstream, with its upstream status           |
| `tools/<tool>/`    | host tools: a build script or our own source; `tools/board/`, the boot-file generators         |
| `keyring/`         | the `apt` repo's public signing key                                                            |
| `kernel/`          | each kernel's pin, config, fragment and patch list, and the step building it                   |
| `build-env/`       | the build environment: one container image every `./build.sh` step runs in                     |
| `modules/`         | each out-of-tree driver: its pin, our patches, the step packaging it per kernel                |
| `uboot/`           | each U-Boot a board package ships: its pin and defconfig, and the step building it             |
| `package/`         | the steps building `tvb-<board>` and `tvb-archive-keyring`                                     |
| `image/`           | the image step, its package list, and the files every image's rootfs gets                      |
| `release/`         | the release plan, the signed `apt` repo, and the upload to GitHub                              |

**Repo files carry no prefix**: each board's `package.list` names where a file installs. A board
directory holds `board.conf`, the tree, the factory idbloader and the maskrom loader,
`package.list`, `preserve-sectors` where it has a `tvb-install`, and firmware only where it is shown
to be this board's. **Shared mechanism lives in `boards/common/`** — a board never keeps its own
copy of a family script. What it may keep is mechanism no other board can use: a unit for hardware
only it has.

**Tools we build, and must:** `dtc` (`./build.sh tool dtc` — vanilla cannot round-trip a vendor blob
with `&label`s) · `rkdeveloptool` (`./build.sh tool rkdeveloptool`) and each board's maskrom loader
(`./build.sh loaders`) · `amlcmd` and `gxlimg` (`./build.sh tool amlcmd`, `./build.sh tool gxlimg` —
Amlogic's own are closed and x86-64 Linux only) · each board's `board.dtb` and `uboot.dts` from its
factory trees (`./build.sh board-dtb <board>`, `./build.sh uboot-dtb <board>`) — or every board's
boot files at once with `./build.sh boards`. **From the host:** `cc` and `patch` · `fdtput` ·
`fsck.ext4` (keg-only on Homebrew: `/opt/homebrew/opt/e2fsprogs/sbin/`) · `xz` · `npx prettier` ·
`python3` · `mtools` and `mkimage`, for a board whose image carries a FAT boot partition. **On the
box:** `evtest`, `fio`, `stress-ng`, `iw`, `bluez`.

**`e2tools`** (`./build.sh tool e2tools`) — edit a box's ext4 rootfs on an SD card or USB stick from
a Mac, which cannot mount ext4; the stock one corrupts an image on delete.

## Where things are written down

**This table is the only index.** Docs are independent — each stands alone and none links to
another, so nothing rots when one is rewritten.

| Doc                                   | Holds                                                                |
| ------------------------------------- | -------------------------------------------------------------------- |
| `docs/board-bringup.md`               | serial, evidence, device tree, board data, offline verify            |
| `docs/board-validation.md`            | the criteria of done, and the caveats behind them                    |
| `docs/first-login.md`                 | a new box's user, timezone, locale and Wi-Fi, by hand                |
| `docs/mpp.md`                         | reaching the video engines; the codec test commands                  |
| `docs/emmc-layout.md`                 | the measured eMMC map: every replicated structure and its sectors    |
| `docs/build.md`                       | `./build.sh`: hosts, steps, outputs, and making a release            |
| `docs/sources.md`                     | every upstream we build from: what floats, what is pinned, and why   |
| `docs/migrate.md`                     | moving a box off the overlay: in place on Rockchip, or a reinstall   |
| `docs/uboot.md`                       | the bootloader pair: what we build, what stays factory, why          |
| `docs/rockchip-maskrom.md`            | Rockchip's USB service modes: entry, the 32 MiB Loader trap, restore |
| `docs/amlogic-burning-mode.md`        | the Amlogic burning gadget: entry, backup, restore, the mask ROM     |
| `docs/watchdog.md`                    | why it cannot be stopped, and why a soft reboot can strand the box   |
| `docs/hdmi-edid-override.md`          | banning a display mode the panel advertises but nothing should pick  |
| `docs/remote-keymap.md`               | validating IR and BLE keymaps separately; the `hwdb` override        |
| `research/<experiment>/`              | dead ends and partial results, kept so nobody re-walks them          |
| `TODO.md`                             | small open items, and where the bigger ones live                     |
| `docs/todo/`                          | open questions — `rk35xx-` is family-wide, `<board>-` is one box     |
| `docs/<board>/board.md`               | that board's identity, measured numbers, known gaps                  |
| `docs/<board>/dtb.md`                 | that board's device-tree changes, tried and reverted ones too        |
| `docs/<board>/worklog*.md`            | dated history, wrong turns included; split by topic once it grows    |
| `tools/dtcx/README.md`                | a blob decompiled as its vendor wrote it: named constants, decimal   |
| `tools/amlcmd/README.md`              | the Amlogic burning-mode client we wrote, and its worklog            |
| `patches/dtc/README.md`               | the patched `dtc` that round-trips a vendor blob with `&label`s      |
| `patches/u-boot/README.md`            | U-Boot's pylibfdt build off Linux; the MAC from vendor storage       |
| `patches/rkdeveloptool/README.md`     | the patched `pack`; why the stock one cannot build a usable loader   |
| `patches/e2tools/README.md`           | the patched `e2tools`; why the stock one corrupts an image on delete |
| `patches/linux-rockchip/README.md`    | the vendor kernel's patches, their PRs, what Rockchip fixed since    |
| `patches/linux-meson/README.md`       | mainline kernel patches for Amlogic boards, on their way upstream    |
| `patches/aic8800/README.md`           | the AIC8800 SDIO driver: Radxa's patches, then ours                  |
| `patches/seekwave-swt6621s/README.md` | the H96 Max Wi-Fi driver patches and their PRs                       |
| `patches/mt76-mt7668/README.md`       | mainline mt76 for the MT7668S: what it does, its gaps, its firmware  |
| `patches/btmtksdio-mt7668/README.md`  | mainline Bluetooth for the MT7668S, in-tree                          |
| `patches/mt76x8-mt7668/README.md`     | the vendor MT7668 driver on 6.18: the fallback, not shipped          |
| `patches/meson-dw-hdmi/README.md`     | mainline HDMI for the GXLX2 (S905L3), in-tree                        |
| `patches/meson-codecs/README.md`      | the video decoder in-tree and the encoders beside it on the GXLX2    |
| `patches/gst-plugins-good/README.md`  | VC-1 through V4L2 on GStreamer 1.26.2: the patched plugin, by hand   |
| `patches/gxlimg/README.md`            | the Amlogic boot-image tool, built on macOS                          |
| `keyring/README.md`                   | the archive signing key: fingerprint, secret, rotation               |

# Standing rules

## Claims and evidence

Five states, meaning exactly what they say:

- **✅ verified here** — run on this box, with the number or output to show for it.
- **🟡 likely** — not verified here, but something proven backs it and nothing indicates a problem:
  the same mechanism ✅ on a sibling board with no sign the boards differ, or a ✅ layer beneath it
  that we do not touch.
- **❓ never tested** — nobody has looked, and nothing predicts the answer.
- **❌ tested and broken.**
- **➖ not present on this box.**

**Verification is per-board.** A shared mechanism earns 🟡, never ✅. 🟡 and ❓ are not
interchangeable: 🟡 has a reason behind it, ❓ is an unknown.

**Check before asserting** — read the file, query the box, run the command. A doc is not evidence
about hardware; reconcile against the box. Don't publish a recipe you haven't run, and when a claim
cannot be backed, say so rather than rounding up.

## Documentation

- **Docs are updated in the same pass as the change.** Work isn't done when the box works; it's done
  when the docs say what the box does. A doc that contradicts the repo is worse than no doc.
- **Docs do not link to each other.** Name a file in plain text if a reader needs it. The index
  above is the only place that points anywhere.
- **Worklogs are written as work happens** — dated entries, wrong turns included. They are the raw
  material everything else derives from, and what the next port follows.
- **Narrative lives in `docs/`**, never in scripts, payload files or DTB tables. Those stay terse.
- **Measured numbers live in `docs/<board>/board.md`** — they're per-unit and they decay.

## Markdown

- **Pure facts. No poems, no prose, no narrative.** A table or a checklist beats a paragraph. Drop
  anything obvious or inferrable — if a competent reader can work it out, it does not go in.
- **Every word earns its place.** Cut relentlessly: a sentence restating the one above it, a caveat
  the command already enforces, an explanation of what the reader can see. Length is the symptom;
  restatement is the disease.
- **One claim per line, backed by the command that shows it — not by your proof that you ran it.**
  "A full pass completes on a full-clock board", never "✅ proven on two boards, spot-verified".
  Dates and evidence belong in `worklog.md`.
- **One command, one line.** The mechanism behind it goes in `docs/todo/` or the patch that
  implements it. Never warn against a command the doc does not give, or defend against a state it
  forbids.
- **Keep a doc around 300 lines** — past that by much, split it or cut it. Two exceptions:
  `docs/<board>/board.md` gets 500, and `worklog.md` has no limit, being append-only history.
- **README is scannable**: no filler, no repeated links, no per-board hardcoding where a pattern
  works. Warnings go in blockquotes. Humour is fine; it must not cost clarity.
- `npx prettier --write` on every markdown file you touch.

## Writing a reference doc

- **One doc, one subject.** Check every block against the title; move what fits only by adjacency.
- **Say where a command runs** — host, box, U-Boot prompt, maskrom. Read in the wrong context, a
  block is a destructive mistake.
- **Blocks in the order they are performed.** "Do this first" under the second block is a bug.
- **Lead with the procedure.** A reference table comes after it, never instead.
- **A table cell is a label, not a sentence.** Markdown is read as source as often as rendered, and
  prettier will not wrap a table: a row past 100 columns is unreadable in the file. Keep cells to a
  few words and put any clause in the prose below.
- **One column, one kind of thing. One row per case.**
- **One name per thing.** Say once that two names mean the same, then pick one.
- **The marker carries the uncertainty.** ❓ already says untested.
- **Never say it twice in two shapes.**
- **Never write ❌ for something nobody tried.** Untried is ❓; reasoned-but-unmeasured is 🟡, with
  the reasoning named.
- **Never enumerate the boards.** State the mechanism and the selector; the per-board answer lives
  in that board's `board.md`.
- **Say "known here"** — never imply a list is exhaustive.
- **A limitation being fixed is current, not permanent.**
- **History belongs in `worklog.md`.** A **date on a claim is evidence, not history**:
  `✅ measured 2026-08-20` belongs.

## Commits

**A title. A paragraph only where it earns its place** — something a reader cannot get from the
diff. The diff is the record; reasoning belongs in the comment, the doc, or the todo it came from.

**Sweep the staged diff before committing**: every hunk belongs to the commit's one change, and no
name, path or claim it touches is left stale elsewhere in the repo.

## Code

Less code is better. Communicate through names, not comments: comment a non-obvious _why_ only,
never what the code already says, and keep it shorter than the code it explains. One responsibility
per script.

## Reach for the lowest layer that can express it

1. **Device tree** — it describes hardware, needs no code, and survives every userspace and init
   change. SoC identity, node enablement, pin routing, LED names, clocks.
2. **udev rule** — device-triggered policy: permissions, names, symlinks. Fires when the device
   appears, so it needs no ordering. The VPU node permissions are here. **A MAC address is not
   settable this way**: `/sys/class/net/*/address` is read-only, so `ATTR{address}=` cannot work.
   The layer-2 mechanism for addresses is a systemd `.link` file, applied by the `net_setup_link`
   builtin — and it takes a literal value, so a computed address has to be written into a generated
   `.link` rather than derived at event time.
3. **systemd unit or hook** — last resort, for behaviour the layers below cannot express. The
   poweroff/suspend LED transitions are here, because DT can turn one LED _off_ at shutdown but
   nothing in DT turns another _on_.

**Do not split one behaviour across layers.** Half in the tree and half in a script is worse than
either alone: the two can fight (the LED core's `LED_CORE_SUSPENDRESUME` versus a sleep hook), and
the next reader must find both. If the lower layer can only do part of it, do all of it in the
higher one and record why.

## Hardware

- **The first login asks for a new root password**: the image ships `1234`, expired. With a network,
  copy an SSH key into `/root/.ssh/authorized_keys` over serial once, and the rest of bring-up runs
  as `ssh root@<BOARD_HOSTNAME>.local`.
- `mmcblk` numbering is **not stable** across images or boots. Identify the eMMC by its
  `boot0`/`boot1` companions, never by a remembered number.
- **After any refactor, rebuild the image and diff every payload file against a pre-change build.**
  Comment-level differences only, unless the change is deliberately a rename — and a path moving
  between packages needs `Replaces` and `Breaks`, which the release guard checks.
- These boxes are daily drivers. Say what you're about to do to them, prefer `--no-reboot` plus an
  explicit reboot you can watch, and keep a known-good DTB where one file copy restores it.
- **When a box won't boot after a DTB change:** power off, pull the SD (if it boots from eMMC, boot
  an SD instead), mount its rootfs on the host and `e2cp` the known-good `board.dtb` back. The boot
  loader reads `/usr/lib/tvb/board.dtb`, the one copy. On serial the two failure shapes differ: a
  silent stop is a hang, a repeating U-Boot banner is a reset loop.
