# Working in this repo

Procedure and rules for anyone — human or agent — adding a board or changing this repo. Most rules
here have a corpse in `docs/*/worklog.md` behind them.

## What this repo is

A thin layer of fixes over a stock Armbian image, not a distro. Kernel and userspace come from
upstream; we carry only what upstream can't know. **Adding a board is data, not code** — one
`firmware/<board>/` directory. If a change needs new code per board, the design is wrong.

| Tree                | Holds                                                               |
| ------------------- | ------------------------------------------------------------------- |
| `firmware/<board>/` | `board.conf`, `board.dts`/`.dtb`, `payload.list`, factory idbloader |
| `firmware/common/`  | everything shared between boards                                    |
| `docs/<board>/`     | `worklog.md` (history), `dtb.md` (tree changes), `board.md` (usage) |
| `stock/<board>/`    | factory evidence: dumps, logs, the box's own DTB                    |
| `backup/<board>/`   | eMMC images (gitignored)                                            |

**Repo filenames mirror the names installed on disk.** New boards use the `rk35xx-` prefix; the R69
keeps its historical `r69-` names because deployed boxes invoke those paths. `BOARD_PREFIX` in
`board.conf` drives every installed path, so there is one code path and no special cases.

**Tools:** `dtc` + `fdtput` · `e2tools` · `fsck.ext4` (keg-only on Homebrew:
`/opt/homebrew/opt/e2fsprogs/sbin/`) · `xz` · `npx prettier`. On the box: `evtest`, `fio`,
`stress-ng`, `iw`, `bluez`.

---

# Bringing up a new board

An evening, if you don't fight it. The fastest path is **copy the closest existing board and change
what the evidence says to change** — the shared parts are already right.

| Phase                      | Who   | Rough time |
| -------------------------- | ----- | ---------- |
| 0 · Serial                 | human | 20 min     |
| 1 · Evidence + backup      | both  | 40 min     |
| 2 · Device tree            | agent | 30 min     |
| 3 · Board data             | agent | 15 min     |
| 4 · Build + verify offline | agent | 5 min      |
| 5 · Validate               | both  | 1–2 h      |

## Phase 0 — Serial first (human, blocking)

Nothing else starts until serial works: it is the only view of U-Boot, early boot, and any hang
before networking.

1. Open the case — plastic pry tool; clips, not glue.
2. Find the 3–4 pin header, usually near the SD slot or the SoC.
3. **Find GND** with a meter: powered box, measure each pin against exposed metal (USB shell, SD
   cage, Ethernet jack) — GND reads 0 V. Of the rest, 3V3 reads highest, TX/RX a few mV below.
4. Wire **GND, TX, RX only**, crossed. Never connect 3V3 — the box is self-powered and tying rails
   can backfeed.
5. `tio -b 1500000 -L --log-file boot.log /dev/…`, then power-cycle.

**Gate:** the vendor boot log scrolls. Adapter must be FT232 or CH340 — a CP2102 can't do 1.5 Mbaud
and prints plausible garbage. TX/RX is a coin flip; swapping harms nothing, but unplug/replug the
adapter between attempts.

**Record** in `docs/<board>/`: pad location, pinout with the square pad marked, board photo.

## Phase 1 — Evidence, then backup (blocking)

The box's own firmware is the specification. Capture it before changing anything.

1. Boot stock Android; get a shell (serial, or `adb` over the network). If neither works, the DTB
   and partitions can still be carved from the eMMC later — but you lose `dmesg`/`getprop`, so try
   first.
2. Dump to `stock/<board>/`: the `boot` partition's DTB, `dmesg`, `cmdline`, `getprop`,
   `/proc/iomem`, `lsmod`, partition table, Wi-Fi/BT firmware from `/vendor`.
3. **Full eMMC image → `backup/<board>/emmc-full.img`**; verify byte count =
   `/sys/block/<dev>/size × 512`. ~25 min at 100 Mb/s — start Phase 2 while it runs.
4. Carve `factory_idbloader.bin` (sector 64, 4096 sectors) → `firmware/<board>/`.

**Gate — no exceptions:** the eMMC dump exists off-box and its size is verified. It is the only
route back to Android once you migrate.

## Phase 2 — Device tree

**Derive `board.dtb` from the box's own factory Android DTB**, never from a reference board's. Apply
only these grafts, each with a functional consumer:

| Graft                                               | Consumer                                     |
| --------------------------------------------------- | -------------------------------------------- |
| debug uart `status` → `okay` + its `xfer` pinctrl   | `ttyS0` console                              |
| `fiq-debugger` → `disabled`                         | frees that UART for `ttyS0`                  |
| IR `remote_support_psci` → `1`                      | remote wakes the box from off                |
| GPU → lima `clocks`/`clock-names`/`interrupt-names` | Armbian uses mainline lima                   |
| LEDs → labels `power`/`standby`, `retain-state-*`   | the shared LED hooks                         |
| `watchdog` → `okay`                                 | systemd `RuntimeWatchdogSec`                 |
| board `compatible` prepend                          | only if a driver keys firmware lookup off it |

**Leave everything else factory**, including the `model` string. If nothing consumes it, don't graft
it. Most `status = "disabled"` nodes are simply unwired on that PCB (i2c, spi, spare uarts/pwms,
audio codecs) — Rockchip's SoC dtsi disables everything and the board file enables what's wired.
Only in-SoC blocks needing no board routing are candidates.

- **Verify the tree round-trips** before rebuilding:
  `diff <(dtc -I dtb -O dts board.dtb) <(dtc -I dtb -O dts <(dtc -@ -I dts -O dtb board.dts))`. If
  it doesn't, edit with `fdtput` instead.
- **Diff the result against the factory tree**; the only differences must be your grafts.
- **One change per test DTB**, serial attached. Two at once cost a day of not knowing which hung the
  boot.
- Record every change in `docs/<board>/dtb.md`, including **tried and reverted** ones.

## Phase 3 — Board data

Copy the closest `firmware/<board>/` and edit: `board.conf` (`BOARD_HOSTNAME`, `BOARD_NAME_LABEL`,
`BOARD_PREFIX`, `BOARD_WANTS`, the two hooks), `payload.list`, `board-id`, `board-name`, plus the
DTB and idbloader. Create `docs/<board>/` (start `worklog.md` on day one, not at the end) and add
the board to the README's Boxes table and support matrix.

- **Anything that must exist on a running box goes in `payload.list`** — that one list is consumed
  by both `build-image.sh` and `rk35xx-update`, so it can't drift. Only one-time image surgery (raw
  loader `dd`, `armbianEnv.txt`, hostname rebrand) belongs in the build script.
- **Never delete files from an image with `e2rm`** — it corrupts ext4 (multiply-claimed metadata
  block → read-only rootfs on first boot). Write an overriding file instead.
- **Never bake in user preferences or big compiled userspace.** An HDMI `video=` pin would cap every
  4K TV to suit one PC monitor; a Kodi/ffmpeg-MPP stack would break the property that makes this
  repo cheap. Document those as recipes.

## Phase 4 — Verify the image offline

Cheaper here than on the box. Attach the built image and check:

- **Loaders byte-identical** to `firmware/<board>/factory_idbloader.bin` (sector 64) and
  `firmware/common/u-boot.itb` (16384) — `dd` + `md5`.
- **DTB** matches `firmware/<board>/board.dtb`; `armbianEnv.txt` has `fdtfile` + the `ttyS0` args.
- **Identity dir** populated: `board-id`, `board-name`, `board.dtb`, both loaders.
- **No other board's names leaked** — grep `/usr/local/sbin`, `/etc/kernel/postinst.d`,
  `/usr/lib/systemd/system-*`, `/usr/src`.
- **Filesystem clean** — the build's `fsck.ext4 -fn` gate must have passed.

---

# Phase 5 — Validation

Flash, boot, then run **every unattended check before asking the human for anything**, and hand them
one batched list. First boot compiles DKMS offline — allow ~4 minutes before assuming a failure.

Test in **risk order**: the things most likely to be wrong on a new board are SDIO Wi-Fi, the
Ethernet PHY, and anything the DTB touches. Prove those before the easy wins.

## Unattended (agent, over SSH)

| Component       | Check                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------ |
| Boot            | `systemd-analyze`; nothing in `blame` waiting on a device that can't exist                 |
| Identity        | `hostname`, `BOARD_NAME` in `/etc/armbian-release`, `/usr/local/share/*/board-id`          |
| No name leakage | `find /etc /usr/local /usr/lib/systemd /usr/src -iname '*<otherboard>*'` → empty           |
| DKMS            | `dkms status` lists every module `installed`; they appear in `lsmod`                       |
| Wi-Fi           | associated; `iw dev wlan0 link` for band and PHY rate; throughput with `nc`, not `ssh`     |
| Ethernet        | link speed/duplex; `readlink /sys/class/net/end0/phydev/driver` — vendor PHY, not Generic  |
| Bluetooth       | `hciconfig` UP RUNNING; `btmgmt find` returns devices                                      |
| CPU             | `scaling_available_frequencies` matches the **factory** OPP table, not a reference board's |
| Thermal         | 5 min 4-core `stress-ng`; idle/peak vs `trip_point_*_temp`; expect no throttling           |
| RAM             | `free -m` vs advertised; `stress-ng --vm --verify`                                         |
| eMMC / SD       | present; `fio` random-4K + sequential, direct I/O, identical parameters on every board     |
| IR receiver     | input node exists and the patched driver bound (check `dmesg`)                             |
| Watchdog        | `/dev/watchdog` exists; journal shows systemd took it; `wdctl` then reports it busy        |
| Suspend         | `systemctl suspend` — confirm it drops off the network                                     |
| Upgrade safety  | `apt-mark showhold` lists `linux-u-boot-*`; `BOARD_NAME` survives an `apt full-upgrade`    |
| Loaders         | after migration, `dd` sectors 64/16384 and md5 against `/usr/local/share/*/`               |

## Needs the human (batch these)

| Component         | Ask                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------ |
| LED polarity      | running = blue? "off" = red? (a dark window during early boot is normal)             |
| IR remote         | press every button while the agent captures `evtest` → produces the keymap table     |
| Wake from off     | press power on the remote — does the box cold-boot?                                  |
| Suspend wake      | resume with the remote, and confirm it **stays** up (no logind double-fire)          |
| Toothpick button  | press it while `evtest` watches the `adc-keys` node                                  |
| HDMI              | picture on a real TV, audio audible; also try a PC monitor for the pixel-clock quirk |
| USB               | a device in each port; USB 3 needs a SuperSpeed device for throughput                |
| SD card slot      | insert a card, confirm it enumerates                                                 |
| AV jack           | 3.5 mm cable — analog audio, composite video                                         |
| Wake-on-LAN       | cable in, `ethtool -s <if> wol g`, suspend, magic packet to **that interface's** MAC |
| BT remote pairing | hold the pairing combo while the agent runs the one-session `bluetoothctl` recipe    |
| eMMC migration    | run `armbian-install`; **read the confirmation device name** before accepting        |

## Done means

- Every unattended check passes and every human check is answered — no cell in the matrix left at a
  guess.
- The box **boots from eMMC** with its own loader pair verified on-device.
- `docs/<board>/board.md` carries identity, names on disk, measured numbers and known gaps; the
  worklog tells the story; the README lists the board.
- Both update paths work: `rk35xx-deploy` from a host, `rk35xx-update --pull` on the box.

---

# Standing rules

## Claims and evidence

Five states, meaning exactly what they say: ✅ verified here, 🟢 likely but unverified, 🟡 not
tested, ❌ tested and broken, ➖ not present on this box. **Never mark something verified because
the mechanism is shared** — verification is per-board.

Check before asserting: read the file, query the box, run the command. Several long-standing "facts"
here turned out to be inherited claims nobody had tested. Don't publish a recipe you haven't run.
When a claim can't be backed, say so instead of rounding up.

## Documentation

- **Docs are updated in the same pass as the change.** Work isn't done when the box works; it's done
  when the docs say what the box does. A doc that contradicts the repo is worse than no doc.
- **Worklogs are written as work happens** — dated entries, wrong turns included. They are the raw
  material everything else derives from, and what the next port follows.
- **Narrative lives in `docs/`**, never in scripts, payload files or DTB tables. Those stay terse.
- **README is scannable**: no filler, no repeated links, no per-board hardcoding where a pattern
  works. Warnings go in blockquotes. Humour is fine; it must not cost clarity.
- **Measured numbers live in `docs/<board>/board.md`** — they're per-unit and they decay.
- `npx prettier --write` on every markdown file you touch.

## Code

Less code is better. Communicate through names, not comments; comment only a non-obvious _why_, and
keep it shorter than the code it explains. One responsibility per script.

## Hardware

- `mmcblk` numbering is **not stable** across images or boots. Identify the eMMC by its
  `boot0`/`boot1` companions, never by a remembered number.
- The R69 image is a **backward-compatibility contract**: after any refactor, rebuild it and diff
  every payload file against a pre-change build. Comment-level differences only.
- These boxes are daily drivers. Say what you're about to do to them, prefer `--no-reboot` plus an
  explicit reboot you can watch, and keep a known-good DTB where one file copy restores it.
- **When a box won't boot after a DTB change:** power off, pull the SD (if it boots from eMMC, boot
  an SD instead), mount its rootfs on the host and `e2cp` the known-good `board.dtb` back. Fix
  **both** copies — `/boot/dtb-*/rockchip/board.dtb` **and** `/usr/local/share/*/board.dtb`, or the
  dtb-persist hook reinstates the bad one on the next kernel update. On serial the two failure
  shapes differ: a silent stop is a hang, a repeating U-Boot banner is a reset loop.
