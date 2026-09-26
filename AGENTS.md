# Working in this repo

Rules for anyone — human or agent — adding a board or changing this repo. Most have a corpse in
`docs/*/worklog.md` behind them. The procedure itself lives in the docs indexed below.

## What this repo is

A thin layer of fixes over a stock Armbian image, not a distro. Kernel and userspace come from
upstream; we carry only what upstream can't know. **Adding a board is data, not code** — one
`firmware/<board>/` directory. If a change needs new code per board, the design is wrong.

| Tree                | Holds                                                                                              |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| `firmware/<board>/` | `board.conf`, `board.dts`/`.patch`/`.dtb`, `uboot.dts`/`.patch`, `payload.list`, factory idbloader |
| `firmware/common/`  | everything shared between boards                                                                   |
| `upstream/<board>/` | the submission header, and the generated submission set                                            |
| `docs/<board>/`     | `worklog.md` (history), `dtb.md` (tree changes), `board.md` (usage)                                |
| `stock/<board>/`    | factory evidence: dumps, logs, the box's own DTB                                                   |
| `backup/<board>/`   | eMMC images (gitignored)                                                                           |
| `patches/<tool>/`   | fixes to host tools we build ourselves, formatted to send upstream                                 |
| `src/<tool>/`       | host tools we write ourselves                                                                      |

**Repo filenames mirror the names installed on disk**, and every board installs under the `rk35xx-`
prefix — `BOARD_PREFIX` in `board.conf` drives every installed path. A board directory holds
`board.conf`, `board-id`, `board-name`, the tree, the loader, `payload.list`, and whatever firmware
is unique to it. **Shared mechanism lives in `firmware/common/`** — a board never keeps its own copy
of a family script. What it may keep is mechanism no other board can use: a `rk35xx-firstboot-board`
hook, or a unit for hardware only it has (the R69's `rk35xx-bt`).

**Tools we build, and must:** `dtc` (`./build-dtc.sh` — vanilla cannot round-trip a vendor blob with
`&label`s) · `e2tools` (`./build-e2tools.sh` — the stock one corrupts an image on delete) ·
`rkdeveloptool` + a per-board maskrom loader (`./build-rktools.sh`) · `amlcmd` and `gxlimg`
(`./build-amltools.sh` — Amlogic's own are closed and x86-64 Linux only) · a per-board `uboot.dts`
(`./build-uboot-dts.sh`) and the `uboot.itb` a board ships (`./build-uboot.sh`) — or all three at
once with `./build-firmware-all.sh`. **From the host:** `fdtput` · `fsck.ext4` (keg-only on
Homebrew: `/opt/homebrew/opt/e2fsprogs/sbin/`) · `xz` · `npx prettier`. **On the box:** `evtest`,
`fio`, `stress-ng`, `iw`, `bluez`.

## Where things are written down

**This table is the only index.** Docs are independent — each stands alone and none links to
another, so nothing rots when one is rewritten.

| Doc                                   | Holds                                                                 |
| ------------------------------------- | --------------------------------------------------------------------- |
| `docs/board-bringup.md`               | serial, evidence, device tree, board data, offline verify             |
| `docs/board-validation.md`            | the criteria of done, and the caveats behind them                     |
| `docs/mpp.md`                         | reaching the video engines; the codec test commands                   |
| `docs/armbian-install.md`             | the factory reserved window: what survives a migration, what does not |
| `docs/emmc-layout.md`                 | the measured eMMC map: every replicated structure and its sectors     |
| `docs/uboot.md`                       | the bootloader pair: what we build, what stays factory, why           |
| `docs/maskrom.md`                     | the USB service modes: entry, the 32 MiB Loader trap, backup, restore |
| `docs/apt-upgrade.md`                 | the hooks and the hold that keep the overlay alive across upgrades    |
| `docs/watchdog.md`                    | why it cannot be stopped, and why a soft reboot can strand the box    |
| `docs/hdmi-edid-override.md`          | banning a display mode the panel advertises but nothing should pick   |
| `docs/remote-keymap.md`               | validating IR and BLE keymaps separately; the `hwdb` override         |
| `research/<experiment>/`              | dead ends and partial results, kept so nobody re-walks them           |
| `docs/todo/`                          | open questions — `rk35xx-` is family-wide, `<board>-` is one box      |
| `docs/<board>/board.md`               | that board's identity, measured numbers, known gaps                   |
| `docs/<board>/dtb.md`                 | that board's device-tree changes, tried and reverted ones too         |
| `docs/<board>/worklog.md`             | dated history, wrong turns included                                   |
| `docs/h96max/wifi-tx-latch.md`        | the 6 Mbit/s TX latch: cause, the shipped fix, how to retest          |
| `docs/r69/upstream.md`                | what the two closed upstream submissions established, and why         |
| `upstream/README.md`                  | turning the grafts into something upstreamable                        |
| `src/<tool>/`                         | a tool we wrote: its README, and the worklog of how it got there      |
| `patches/dtc/README.md`               | the patched `dtc` that round-trips a vendor blob with `&label`s       |
| `patches/u-boot/README.md`            | the two fixes U-Boot's pylibfdt build needs off Linux                 |
| `patches/rkdeveloptool/README.md`     | the patched `pack`; why the stock one cannot build a usable loader    |
| `patches/e2tools/README.md`           | the patched `e2tools`; why the stock one corrupts an image on delete  |
| `patches/linux-rockchip/README.md`    | the kernel fixes and their PRs; why an overlay box cannot apply them  |
| `patches/seekwave-swt6621s/README.md` | the H96 Max Wi-Fi driver patches and their PRs                        |

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
- **`upstream/<board>/header.dts` lists exactly what that board's `board.patch` changes** — no more,
  no less. It is the submission's only account of why the tree departs from the factory blob: a
  missing entry reads as an unexplained change, and an entry inherited from another board claims a
  change this one never makes.
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

- `mmcblk` numbering is **not stable** across images or boots. Identify the eMMC by its
  `boot0`/`boot1` companions, never by a remembered number.
- **After any refactor, rebuild the image and diff every payload file against a pre-change build.**
  Comment-level differences only, unless the change is deliberately a rename — and a rename of an
  installed path is a breaking change for deployed boxes, so it needs a removal step in
  `rk35xx-update` for what it replaces.
- These boxes are daily drivers. Say what you're about to do to them, prefer `--no-reboot` plus an
  explicit reboot you can watch, and keep a known-good DTB where one file copy restores it.
- **When a box won't boot after a DTB change:** power off, pull the SD (if it boots from eMMC, boot
  an SD instead), mount its rootfs on the host and `e2cp` the known-good `board.dtb` back. Fix
  **both** copies — `/boot/dtb-*/rockchip/board.dtb` **and** `/usr/local/share/*/board.dtb`, or the
  dtb-persist hook reinstates the bad one on the next kernel update. On serial the two failure
  shapes differ: a silent stop is a hang, a repeating U-Boot banner is a reset loop.
