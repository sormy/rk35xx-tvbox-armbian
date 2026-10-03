# The Mortal T1 got Armbian — bring-up worklog

Mortal T1 (label: "MORTAL Model T1, RAM 16GB / ROM 256GB"), PCB silkscreen **XR82235518K-V1.0**
(actual: `XR8223518K-V1.0`), RK3518, no ethernet, TF slot, USB-A 3.0 OTG flash port. No public
firmware exists for this box (XDA threads asking for it; the "Mortal T1" firmware that circulates is
the **Allwinner H313** variant — wrong SoC entirely).

Told in the order it happened.

## 1. Maskrom recovery (before this repo was involved)

The box was wedged (reboot-looping through vendor Loader on a flaky internal-hub port — moving it to
a rear root port with the reset button held got a stable BootROM Maskrom). Tools: `rkdeveloptool`
v1.32 + RKDevelopTool-GUI, udev rule `99-rk-rockusb.rules` covering `2207:350c`.

Loaders built from this repo's `build-rktools.sh` with the **box's own factory DDR** (carved from
the stock idbloader) worked where rkbin generic DDR variants hung:

```
db rk3528_spl_loader-mortal-t1.bin   → rfi: SAMSUNG, 7456 MB, 15269888 sectors
```

## 2. Full eMMC backup — the evidence base

`rl` in 1 GiB chunks → `mortal-t1-eMMC-stock.img`, 7,818,182,656 B (15,269,888 sectors), md5
`6537dc0b8a25c421ec108ae03594acbb`. First 16 MB byte-identical to an independent earlier read. Reads
past the vendor loader's silent 32 MB cap verified (double-read identical).

Everything below was carved from that image — the box was never asked to boot anything.

## 3. What the dump revealed (the "masked specs" question)

|          | Truth (measured)                                                                                                  | Label / stock Android claims                                                |
| -------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| SoC      | RK3518 (RK3528-family), 4× Cortex-A53 @ 1.42 GHz, `rk3528` platform                                               | OK                                                                          |
| RAM      | **2 GB** — SPL symbol `rk3518a1_max_2gbyte_limit`; Android runs `ro.config.low_ram=true`; all sibling boards 2 GB | 16 GB                                                                       |
| eMMC     | **7455 MiB Samsung** (8 GB class) — GPT ends at LBA 15269854, `rfi` agrees                                        | 256 GB                                                                      |
| Identity | `rk3518_box_32`, `ro.fota.device=XR822_A52_T1_14`                                                                 | spoofed `brand=google`, `model=Google_TV`, **Pixel 5 (redfin) fingerprint** |
| OS       | Android 14 API 34, **32-bit only** (`abilist64=` empty), built 2026-05-26                                         | —                                                                           |

No `16GB`/`256GB` spec claim exists anywhere in the firmware (grep of the full image: every hit is a
glibc constant or Chromium histogram bucket) — the fake numbers live on the sticker and in the
seller's launcher, not in Android. The fingerprint spoof is certification fraud (Play/Widevine), a
different lie from the sticker.

## 4. Board bring-up (this repo's pipeline)

Per `docs/board-bringup.md` — _adding a board is data, not code_:

- **Factory trees**: `stock/mortal-t1/board.dtb` = the kernel DTB from the eMMC `boot` partition
  (both FDTs in `boot.img` byte-identical, md5 `7e4cf9b6…`); `stock/mortal-t1/uboot.dtb` = U-Boot
  control DT from the `uboot` partition (embedded twice, md5 `c252300d…`).
- **Factory kernel DTB vs r69's**: 26 diff lines total, all 1:1 — the IR key tables/usercodes
  (different remotes) and one `status` (`u2phy_otg`: r69 okay, ours disabled). Line numbering is
  identical, so r69's proven `board.patch` context applies verbatim at `-F0`.
- **Factory U-Boot DT vs r69's**: one line — `max-frequency` 80 MHz (ours) vs 50 MHz (r69), outside
  every patch hunk.
- `firmware/mortal-t1/board.patch` / `uboot.patch` = r69's with only `model` + board `compatible`
  adapted. Grafted-tree diff vs factory shows exactly the 11 documented grafts, nothing else.
- Board data copied from r69 (AIC8800D80 Wi-Fi policy — our DT is r69-identical, same SDIO +
  `sdio-pwrseq` wiring), `mac-oui` = `wlan0 00:1c:79` (label MAC `001C79A17192`; no ethernet).
- Toolchain: Solus has no cross-gcc → pixi/conda-forge `gcc_linux-aarch64`
  (`CROSS_COMPILE=aarch64-conda-linux-gnu-`), plus `swig`, `libgnutls-devel`, `e2fsprogs-devel`,
  `pyelftools` for the host tools.

## 5. Status / next

- [x] board.dts + board.dtb built and verified (round-trip clean, graft-only diff)
- [x] board data (board.conf, payload.list, mac-oui, identity, BT/firstboot scripts)
- [x] e2tools (patched, self-test pass), Armbian 26.8.1 Rock-2f trixie vendor 6.1.115 minimal
      (sha256 OK)
- [x] uboot.itb for mortal-t1 — `build-uboot-dts.sh` (29 clock / 11 reset cells retargeted, `-F0`
      patch pass; vs r69 exactly 2 lines: `model` + factory `max-frequency` 80 MHz) → mainline
      U-Boot v2026.04 FIT built with the conda cross-gcc
- [x] **`build-image.sh`** → `Armbian_26.8.1_Rock-2f_trixie_vendor_6.1.115_minimal-mortal-t1.img` (2
      327 838 720 B)
- [x] **Offline verification** (docs/board-bringup.md checklist, all green): idbloader @64 and
      uboot.itb @16384 byte-identical to `firmware/mortal-t1/`; `board.dtb` md5 `6e58584e…` at both
      `/usr/local/share/rk35xx/` and `/boot/dtb-6.1.115-vendor-rk35xx/rockchip/`; `armbianEnv.txt`
      has `fdtfile=rockchip/board.dtb` + `earlycon … console=ttyS0,1500000`; identity dir complete;
      no other board's payload data (the only `r69` strings are legacy pre-rename migration lines
      inside the **family** scripts, byte-identical to repo source — present in every board's
      image); `e2fsck -fn` clean.
- [x] **Validation** (human, blocking): serial console (`docs/board-bringup.md` § serial first), SD
      boot, then the `docs/board-validation.md` checklist. Exact RAM figure gets its definitive
      proof from Armbian `dmesg` (2 GB expected). Closed by the §6–§8 sweeps.
- Assumption to check on hardware: Wi-Fi is AIC8800**D80** SDIO (inferred from the r69-identical
  factory DT; XDA photos of another T1 mention AIC8800 without variant).

## 6. Validation sweep, day 1 — three root causes (2026-09-27 – 28)

Remote sweep ran against the flashed SD image over SSH (`.49`), per `docs/board-validation.md`.
Passing checks: spec truth, fio, thermal, Wi-Fi 5 + 2.4, GPU/Mesa, MPP gate, codec matrix, overlays,
watchdog, dmesg census, CEC/USB/input enums, ten-warm-reboot loop (10/10, log kept on the box at
`/root/reboot-loop.log`). Numbers go to `board.md` in the docs pass.

| #   | Symptom                                                                               | Root cause                                                                                                                                                     | Fix                                                                                                |
| --- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | DHCP lease churn (.49/.16/.183…) read as a stranded box                               | `rk35xx-mac-pin derive()` shells out to `cut`; `/usr/bin/cut` corrupted on the SD                                                                              | restore from `coreutils_9.7-3_arm64.deb`; `dpkg -V coreutils` clean; `.49` stable every boot since |
| 2   | `rk35xx-bt` never attached at boot — `hci0 did not appear on /dev/ttyS2`, 11/11 boots | `modules.alias.bin` corrupted on the SD — starts `p000`, index magic is `b007f457` — so `modprobe tty-ldisc-15` fails `FATAL` and `hciattach` cannot set N_HCI | `depmod -a`; `rk35xx-bt` now `modprobe hci_uart` by name before attaching                          |
| 3   | tty1 renders substituted glyphs                                                       | dirty SD card, caused by a faulty card reader                                                                                                                  | closed by user — no probe run                                                                      |

- Corruption is box-side only: image copy healthy — `/usr/bin/cut` md5
  `202326548155a0b39ade6938a77c5b31` (box had `65113eada64dc44c7b860e8bb5f0cce1`), all five depmod
  indexes start `b0 07 f4 57`.
- Cause of the box-side rot unknown ❓: `tune2fs -l /dev/mmcblk1p1` state clean, no EXT4 or I/O
  errors in dmesg, no mmc CRC lines. `modules.alias.bin` mtime lost when `depmod -a` regenerated it.
- BT boot fix verified on reboot 2026-09-28 08:30: `rk35xx-bt` active, `hci0` present,
  `Device setup complete`, BD address `0B:3B:22:AC:88:20`.
- `permaddr` is a fresh random `88:00:33:77:xx:xx` per boot (…`31:d9` → …`06:a6` across boots
  09-28); `wlan0` stays `02:1c:79:97:7b:ae` derived — that is the churn the pin exists for.
- `rk35xx-bt` + unit moved to `firmware/common/`: they were byte-identical on r69 and mortal-t1;
  both `payload.list`s updated in the same change.
- Console forensics: `setfont -o` dumps and `GIO_UNIMAP` (791 entries) identical across ttys;
  `KDGKBMODE` equal; `dpkg-reconfigure console-setup` and a re-sent `ESC % G` did not clear it.
  Probe = marker line to `/dev/ttyN` → `/dev/vcsN` cells vs `/dev/vcsuN` Unicode.
- Wrong turn, kept: console garble was first blamed on the rotted `cut` — `console-setup` scripts
  never invoke `cut` (the grep matched "ex**cut**e" in comments).

Still open: dpkg corruption scope (`debsums` flagged six `.md5sums`/`.list` files: `cec-utils`,
`libdrm2`, `libncurses6`, `liborc-0.4-0t64`, `x11proto-dev`, `xorg-sgml-doctools`) →
`apt-get install --reinstall` then the full-upgrade test; display tests and the cold-boot physical
batch await the human. Console garble closed by user: dirty SD card, caused by a faulty card reader.

## 7. Validation sweep, day 2 — dpkg rot, a retracted test, clean-slate restart (2026-09-28)

Continuing §6 remotely; ends with a decision to reflash the SD clean and restart the sweep with no
package upgrade. Off-box state preserved first (`/tmp/opencode/preserve/`).

### dpkg corruption — scope and repair

- `debsums -c` → 7 packages, not 6: `cec-utils`, `x11proto-dev`, `xorg-sgml-doctools`, `libdrm2`,
  `libncurses6`, `liborc-0.4-0t64`, `libx11-6`.
- Two shapes: `.list` missing, and control-file content rotated among the seven (e.g. `libdrm2`'s
  `.triggers` held its md5sums content; four `.triggers` corrupt the same way).
- dpkg is fatal on a corrupt control file but only warns on a missing one → delete the corrupt file,
  `apt-get install --reinstall <pkg>`, `dpkg --configure -a`.
- After: all 7 `dpkg -V` clean, `dpkg --audit` empty, re-verified after `drop_caches` (persist at
  rest); `debsums -c` changed-list = only expected artifacts (firstboot files, depmod indexes,
  image-build tweaks).
- Scope sweep: every `/var/lib/dpkg/info/{*.md5sums,*.list,*.triggers}` + maintainer script scanned
  — no other corruption; 24 non-comment `.triggers` all legit.
- Preserved on host: corrupt `xorg-sgml-doctools.list` + zeroed `/var/log/dpkg.log`,
  `apt/history.log`, `apt/term.log` (zeroed 09-27 20:00, cause ❓; dpkg.log worked again after) →
  `/tmp/opencode/preserve/forensics.tar`.

### Storage tests — one retraction

- The failing checklist was a harness bug: `sha256sum -c` with filename field `-` hashes empty stdin
  and prints `-: FAILED` unconditionally (reproduced on the host). Retracted.
- Corrected, all PASS: 1200 MB write→sync→`drop_caches`→re-hash; 4000×32 KB small-file storm; 256 MB
  python round trip; `modprobe tty-ldisc-15` silent after cache eviction.
- Verdict: card **suspect, not convicted**. Live corruption evidence = §6's file forensics only —
  historical, mechanism unknown, not reproducible: `tune2fs -l` clean, zero EXT4/I/O errors in
  dmesg, synthetic tests clean.

### At-rest sweeps vs the image

- `usr/bin`+`usr/sbin` (880 files): only `curl` differs — the post-firstboot update was exactly
  `curl`/`libcurl4t64` 8.14.1-2+deb13u4→deb13u5; 58 box-only = toolkit; none missing.
- `lib/modules`+`lib/firmware`+`usr/lib/aarch64-linux-gnu` (2279 joined): only depmod indexes +
  `libcurl.so.4.8.0` differ (expected); 3 only-in-image =
  `updates/dkms/aic{8800_fdrv,btusb,load_fw}_usb.ko` ❓ — the box has
  `rockchip_pwm_remotectl_rk35xx.ko` there instead, `dkms status` = rockchip-pwm + v4l2loopback, no
  aic sources in `/usr/src`. Non-blocking: box Wi-Fi runs the kernel-tree SDIO `aic8800_fdrv.ko`, BT
  is UART — the USB variants are unused here; how the box dropped them without a directory-mtime
  bump ❓.
- `apt-get -s full-upgrade` ran clean ("65 not upgraded", would pull `linux-image-vendor-rk35xx`
  26.8.3) — the survival test itself was dropped, see below.

### Donor-era mtimes = `fake-hwclock-load`

- Box files created during firstlogin carry Aug 15 14:18–14:20 mtimes: the image ships
  `/etc/fake-hwclock.data` = `2026-08-15 06:17:16` UTC (donor build clock), the enabled
  `fake-hwclock-load.service` (`sysinit.target.wants`) applies it at boot, NTP corrects only after
  Wi-Fi comes up. The Wi-Fi YAML is born load+3m18s (`2026-08-15 14:20:34 +0800`); `authorized_keys`
  (19:10) and the toolkit install (19:20) are real time.
- `systemctl is-enabled fake-hwclock` → `masked` is the legacy unit (Debian default, symlink from
  the package build) — not the load unit, and not ours.

### Clean-slate restart (user decision)

- Reflash the SD from `FLASH-THIS_Mortal-T1_Armbian.img` (built 09-28 08:35, sha256
  `e11c9c09…65de`), start the sweep over, **no package upgrade** — full-upgrade survival test
  dropped (`docs/apt-upgrade.md`: r69 ✅, T1 ❓).
- Reasoning: card-side corruption never explained; a clean baseline with no upgrade isolates the
  variable. If rot returns, the signal is sharper.
- Off-box state in `/tmp/opencode/preserve/`: `secrets.tar` (`authorized_keys`, BT pairing
  `0B:3B:22:AC:88:20`), `30-wifis-dhcp.yaml` (Wi-Fi is box-side: firstlogin-created, absent from the
  image), `forensics.tar`, `toolkit-pkgs.txt` (114 = box-minus-image, arch-normalized),
  `box-pkgs.txt`.
- Image carries neither Wi-Fi config nor SSH keys → after reflash: console firstlogin on the TV
  (root pw, Wi-Fi), first SSH contact by password (no sshpass/expect on the host → python pty), key
  restored from `secrets.tar`. mac-pin is image-baked → expect `.49`.

## 8. Validation sweep, run 2 — full remote pass, codec matrix, one shipped fix (2026-09-28)

Run 2 on §7's clean image (sha256 `e11c9c09…65de`), no package upgrade of any kind (user decision;
toolkit via `apt-get install --no-upgrade`, 114/114; `dpkg -V` baseline 29, integrity re-test clean
after `drop_caches`). Root password chosen per boot (kept out of these docs). Numbers live in
`board.md`; this is how they got here.

### The 8 GB card dies — convicted, retired

- During run 2 the original card went read-only twice across two flashes; CID PNM `asdfg` — a
  placeholder string, not a vendor. Convicted on the spot evidence, retired.
- The user's 16 GB spare (`SU16G`, 14.8 G, now `mmcblk0`) was never implicated and became the
  running card. With it went the full-upgrade survival test (dropped by decision before the card
  died anyway) → `docs/apt-upgrade.md` keeps T1 ❓, and dtb-persist's kernel-update leg is a note,
  not a ❌: no upgrade was run.
- bluez gap: confirmed documented behavior (README pairing section, `toolkit-pkgs.txt`), not a repo
  bug — nothing to fix.

### Wi-Fi and radio — one section closed, one impossible

- Under-load A/B interleaved 12 runs: TX 11.6–23.2 / RX 8.5–40.3 Mbps either phase, `tx failed: 0`
  everywhere, run-to-run variance 6.8–38 Mbps swamps any load effect → **no defect**, neither remedy
  ships (rps_cpus, IRQ 57 affinity): the remedy ships only with the measurement that justified it.
- IRQ 57 (`dw-mci`) is the SDIO Wi-Fi controller (61,382 ints in 12 s of RX, all CPU0); IRQ 59
  (`mmc2`, eMMC) silent on Wi-Fi traffic.
- Regdomain criterion trivial: `iw reg set` rc=0 + the box answers — global stays `country 98`
  (vendor-permissive), `phy#0 (self-managed country 00)`: the driver owns the radio, so user hints
  never reach it; effective `US` comes from the AP Country IE via wpa.
- `chrt -f` EPERM even as root: `CONFIG_RT_GROUP_SCHED=y` + cgroup v2 (also via `systemd-run`;
  `nice -5` works). Board fact, not a defect — the RT-priority test row cannot run here.
- 2.4 GHz band measured without touching config: AP steered the box to ch4 (2457) after a reboot →
  10.7 up / 8.5 down / 8.8 Mbps under 4-core load, post-load PHY back to 103.2 HE-MCS8 — no latch.
- Tool quirks worth remembering: `station dump` empty → `station get <bssid>`; `pkill`/`pgrep`
  self-match over SSH; `xxd` absent on the box → `od -A d -c`.

### Codec matrix — MPP as `twilight` (53 sections, `/home/twilight/codec-matrix.log`)

- Root-built trees are unreadable to a normal-user test → MPP built as `twilight`
  (`/home/twilight/mpp-build`, `MPP-BUILD-OK` in `/root/build-mpp.log`); tests run via
  `su - twilight`. Gate: `match chip name: rk3528a`, `dec 00f0079c enc 00100180`, plus benign
  `confliction found at client_type 3` (kernel vcodec_type `0x3001320a` vs soc `0x00013202`).
- **VP8 above 1080p is silent corruption**: 4K/8K report rc=0 and 30 frames at _higher_ fps than
  1080p (203/77 — the tell), `-o` output is frame 0 real then all-zero black. 1080p and below real.
- **MPEG-2/MPEG-4 above 1920×1088 hang**: parser loops `Warning: unsupport larger than 1920x1088`,
  zero codec IRQs, `timeout` rc=124, process-local (next run unaffected).
- **AV1 refused by name**: `mpp: unable to create dec av1 for soc rk3528a unsupported` rc=255.
- **AVS/AVS+/AVS2 create accepted** (`-t 16777221/2/3` build the decoder, then stall on the foreign
  bitstream — no refusal) → 🟡 no clip is honest, not ❌/➖. h96max-3518d's "AVS2 357 fps" still has
  no worklog provenance — flagged in `board.md`, not inherited.
- H.263 accepts only its fixed sizes; matrix cell runs CIF 352×288 (833.2 fps).
- IRQ map from 30-frame deltas (one IRQ per frame): 65 `rkvdec` H.264/HEVC/VP9 · 64 `jpegd` MJPEG ·
  63 `avsd_plus`+`vdpu` shared VP8/MPEG-2/MPEG-4/H.263 · 66 `rkvenc` encoders.

### Ten warm reboots + a BD loop (11 snapshots, `/root/warmboot.log`)

- Root mounted every boot (PARTUUID); SD block index flipped mmcblk0↔mmcblk1 on 3 of 11 — the AGENTS
  rule about `mmcblk` numbering is now measured, not theoretical.
- `.49` and both MACs every boot (end0 `a2:ef:8d:dd:ca:58`, wlan0 `02:1c:79:97:7b:ae` derived);
  wlan0 associated 0 s wait; `hci0` up; all input nodes + `ir-target=event9`; `/dev/video0`;
  `fake-hwclock.data` saved 11/11.
- Dedicated BD loop: `0B:3B:22:AC:88:20` captured 4× over three more reboots — identical.

### Storage — one measurement bug found and corrected, one accident recorded

- **fio SD read was an artifact**: `time_based` read of a partly-unwritten file — DIO reads of
  unwritten extents zero-fill in RAM → a "143 MB/s seq read" that no 50 MHz card can do. Redone on a
  fully-written file with caches dropped: seq read 23.9 MB/s, raw `dd iflag=direct` 23.7 MB/s — the
  High Speed ceiling. DT (stock-identical) has no `vqmmc-supply` → no 1.8 V → UHS/SDR104 impossible,
  same as h313. Writes were always real (5.4 MB/s, consistent across both runs).
- **eMMC fio from offset 16 M overwrote stock partitions** (`misc`, `super`; `boot` lost
  `ANDROID!`). Verified scope: `uboot`@16384 `d00dfeed` intact, GPT + boot0/1 untouched, `DVKR`@7168
  and `SSKR`@8192 still tagged, vendor storage `lan` = `00:1c:79:a1:71:92` = the sticker. Restore =
  `dd` of `mortal-t1-eMMC-stock.img`, no maskrom needed.
- Full-disk read one pass: 7.8 GB / 94.7 s / 82.5 MB/s, no stall (eMMC).

### System facts harvested

- Second boot 20.650 s; blame top `rk35xx-bt` 6.2 s, `armbian-ramlog` 3.0 s, `rk35xx-mac-pin` 2.7 s
  — nothing waits on end0/DHCP (the PHY probe fails async, outside the critical chain).
- Watchdog: journal `hardware timeout of 1min 29s` = 89.5 s = `2^(16+15)/24 MHz` → granted step is
  TOP 15, the largest the clock allows; `wdctl` busy under systemd.
- Thermal: idle 48.3 °C, 300 s peak 58.3 °C, no throttle; `stress-ng --vm --verify` 4/0; OPP
  `{1200000, 1416000}` — `dtc` diff of stock vs ours `operating-points-v2` blocks empty (factory
  comparison, not by eye).
- RTC absent (no `/dev/rtc*`, no `/sys/class/rtc`, no dmesg line) → absence recorded, not ❌.
- `v4l2loopback` shipped in the image but never loaded → box-side
  `/etc/modules-load.d/v4l2loopback.conf`; persists across all reboots.
- dmesg census: gmac pair + `WARNING … devm_gpiod_put` (`stmmac_mdio_reset` on absent reset-gpios)
  once per boot, `Cannot find any crtc or sizes` ×2, everything else a singleton — all named in
  `board.md`. Our gmac and mmc nodes are byte-identical to stock: the `-110` is this PCB's PHY not
  answering, and the RJ45 look (physical) decides whether `gmac` gets its `NOT FITTED` hunk.
- DKMS rmmod/modprobe cycle: both modules return, `ir-remote`/`video0` recreated. `btmgmt find`:
  discovery starts, LE devices found (`BLE MF8470`).
- `egl-tri` (surfaceless, no display): 157/163/168 Mpix/s at 720p/1080p/4K, Mali450, Mesa 25.0.7.
- `build-board-dts.sh mortal-t1` regen byte-identical to the shipped DTB (`6e58584e…`, same as the
  running box) → rebuild check cite-able, no tree change this run.

### Update paths — one defect found and fixed

- `./rk35xx-deploy root@… --no-reboot` from the host: full pass rc=0 (payload, DKMS rebuild, DTB
  "unchanged — no reboot needed", FIT slots current, systemd reloaded). Host had no rsync (Solus, no
  apt) → built rsync 3.4.1 from source into `/tmp/opencode/rsyncroot` — no system change, no
  upgrade; routine deploys still need a host rsync install (physical handoff item).
- `rk35xx-update --pull`: clean clone to `/usr/local/share/rk35xx/repo` then expected
  `unknown board 'mortal-t1'` rc=1 (GitHub remote lists h96max-3518d, h96max-h313, r69 only — T1
  unpushed).
- **Defect**: pull after deploy aborted — deploy's `rsync -a` writes host uids (1000:1000, dir
  twilight) next to root-owned `.git` → git's safe.directory check fails under `set -e`; without a
  stale `.git` the clone would land in a non-empty dir instead. Fixed in `rk35xx-update`: probe
  `git rev-parse --git-dir` instead of `-d .git`, and `rm -rf` + fresh clone at the machine-managed
  path (in-place checkouts keep pull-in-place, never deleted). Retested on the box: clean re-clone
  root:root → `unknown board` rc=1. Box copy scp'd to `/usr/local/sbin/rk35xx-update` mode 0755;
  payload line already ships it.

### Still open after this run

- Display-dependent checks and the physical batch (cold boot, maskrom button, IR/BLE per-transport
  keymaps, LEDs, suspend/wake, USB sticks, power meter, eMMC migration + restore, RJ45 look) —
  handed over as one list in `board.md`.
- Console garble root cause (❓ at the time): tty1 substitutes CP437-ish glyphs, tty2 clean; probe
  recipe in §6 — since closed: dirty SD card, caused by a faulty card reader.

## 9. Display across three TVs, Kodi 21.2, one locked box (2026-09-28 – 29)

Run-2 follow-up on the display criterion, plus Kodi the next day; `--no-upgrade` throughout. Numbers
in `board.md`; this is how they got here.

### Sharp → Prism+ 65″ direct (2026-09-28, 17:38 – 18:58)

- Off the 2-port switch onto a direct HDMI run; `hpd-watch.sh` (600×1 s) caught the real cycle: 357
  samples `st=disconnected hp=lo irq=94` → 243 `st=connected hp=hi irq=95+` (`/root/hpd-watch.log`)
  — replug re-detect measured, not assumed.
- EDID: the first read garbled (the tolerated `ddc read failed` ×4–5), a re-read settled it — Prism+
  `3840x2160` ×5 + `4096x2160` ×2, later reads `3840x2160@60` preferred. Sharp: EDID byte-identical
  over two reads, 1080p driven, bare `kmscube` as `twilight` 50.002 fps.
- 4K60 on screen: `/root/mpv4k-test.sh` walks `--drm-mode` — the flag takes `WxH[@R]`, so
  `3840x2160-25` dies at parse and plain `3840x2160` wins; dmesg
  `Update mode to 3840x2160p60 … dclk 594000000`, 90 s of `/home/twilight/clips/hevc.4k.hevc` (25
  fps, no PTS — lavf warns, mpv invents timing, harmless for a loop), 1 dropped frame
  (`/root/mpv4k.log`).
- CEC: the adapter configures (LA4, TV OSD `T1`) and then talks to nobody —
  `/root/cec-audio-test.log` ends `Tx, Not Acknowledged (4), Max Retries`; `/root/cec-raw.log`: PA
  `3.0.0.0`, empty topology, polls LA0/LA2 unanswered. No responder on Sharp or Prism+; no TV's CEC
  menu was ever opened (physical leftover).

### Kodi 21.2 (2026-09-29)

- The earlier blocker: kodi needs `libpython3.13` (absent), its candidate `…deb13u5` exact-depends
  the whole python set → 4 upgrades. Pinning all five packages to `3.13.5-2+deb13u4` (trixie-updates
  still carries it) lands `0 upgraded, 69 newly installed`; u-boot hold untouched. First attempt
  aborted at the `[Y/n]` (no TTY) — `-y` fixed it.
- First run: `CDRMUtils::FindConnector HDMI-A-1`, `GL_RENDERER = Mali450`, `kodi.bin` holds DRM
  master (direct-to-plane), ALSA `sysdefault` → card 0 `rockchiphdmi`. Debian 21.2 builds
  GBM+Wayland+X11 windowings but hwdec `vaapi`/`mediacodec` only — libva probes
  `rockchip_drv_video.so` and gets `-1` (`/root/kodi-run.log`) → no hwdec exists here, every player
  decodes in software.
- **Wrong turn:** with kodi holding DRM master I wrote `off`→`on` to the connector's `status` sysfs
  to force an EDID re-read — modeset deadlock, network gone, the 89.5 s watchdog did not recover it,
  the box needed a power cycle. HPD is a hardware input: there is no software EDID re-read — replug
  the cable, and never touch `status` while anything holds DRM master.
- The power cycle landed on a **third** set — a Toshiba, generic EDID (`mfr XRR`, top mode
  `1920x1080`, no 4K), which is what made both boots look like the Prism+ losing its 4K. Kodi
  restarted there fine, and the sink set in Kodi's audio settings was heard through the TV. No
  pipewire/pulse exists (`pactl` absent, 0 processes) — ALSA card 0 is the entire audio story.

## 10. IR remote decoded, gmac gets its NOT FITTED hunk (2026-09-29)

Both fixes ride in one `board.patch` rebuild; numbers in `board.md`, node list in `dtb.md`.

### Decoding the remote

- Transport was settled first: keys arrive on `event9` (pwm remotectl, IRQ 27) — the USB dongle
  (`0513:0318`, event4–7) logged 0 events while keys flowed, and `hci0` has no paired device. The
  handset also advertises BLE on its own a few minutes after boot (Android announced it), so BLE
  stays an open, separate keymap per `docs/remote-keymap.md`.
- **The trap:** unanchored ordered passes misalign. The user does not press strictly in the printed
  order, and one pass lost four presses mid-list — which silently shifts every later label (that is
  how OK first looked like `KEY_HOME` and vol− like `KEY_SETUP`). The fix was method, not more
  presses: one button per burst with the **settings gear pressed last as an anchor**; if the anchor
  lands where it should, the order held. Two to three identical repetitions per round then make the
  mapping overdetermined. (This driver emits no `MSC_SCAN`, so scancodes can only come from
  inverting the table itself.)
- Result: all 24 buttons decoded, `ir_key1`/`ir_key4` (usercodes `fb05`/`fb04`, byte-identical)
  cover them, plus one stock pair (`b5` → `KEY_MENU`) that never fires. OK was the blocker: stock
  maps it to `KEY_REPLY`, which Kodi never binds; `KEY_ENTER` is what it needed.
- The table rewrite picks icon-sane keycodes (OK → `ENTER`, back → `BACKSPACE`, X → `DELETE`,
  dpad/levels sane already, P± → `CHANNELUP/DOWN`, app row → `PROG1…PROG4` — `PROG3/4` are 202/203,
  not 150/151, per this kernel's header). home/source was the one true ambiguity — both emit
  `KEY_HOME`, scancodes `d2`/`60` — so the guess had to survive a post-deploy test: it did, three
  buttons × three rounds, `28`/`102`/`241`, no flip needed.

### gmac

The user's photo shows no RJ45, and the RMII PHY answered `-110` every boot
(`phy_poll_reset failed`, `Cannot attach to PHY`). One hunk disables `gmac0` with the reason in a
comment; `rmii0_phy` is its child and never probes. `mac-oui` already documented "no ethernet on
this PCB" — untouched. The user later confirmed the design intent: wireless-first cost cut (no jack,
no magnetics), and the online specs that list a LAN port are copied from other boards — the same
kind of copy that gives this box its false 16 GB / 256 GB label.

### The button beside HDMI

Earlier reports called it the maskrom trigger (no toothpick hole exists — first useful fact). The
user then tested every pattern: single press, two presses 1-2 s apart, third press held 10 s — **it
never reaches maskrom and never powers off**; by all appearances inert. Maskrom entry on this unit
is therefore the software path only: `reboot maskrom` via the `mode-maskrom` hunk (✅ since §21,
2026-09-30), with the flash USB on a host beforehand, and a power cycle to get out again. An RK box
that shows no force-off either suggests nothing is wired to it — worth one look inside during the
eMMC trip.

### Build, deploy, verify

- Patch regenerated from the stock decompile (12 hunks); `build-board-dts.sh` round-trip `cmp`
  clean; the binary DTB diff is exactly the two IR tables + gmac `status` (6 lines).
- The host had no `rsync` (Solus: `eopkg install rsync`, 3.5.0) — deploy otherwise unchanged:
  `rk35xx-deploy --no-reboot`, then an explicit watched reboot.
- Back in 60 s: zero gmac/phy/stmmac lines in `dmesg`, no `end0`, live tree `status = "disabled"`,
  wlan0 + SSH up, both tolerated gmac rows now deletable from the log. evdev re-verify as above;
  `kodi --standalone` restarted (GBM, ALSA card 0).
- Open: BLE pairing + BLE keymap, mic, LED polarity, suspend/wake, IR cold-boot power-on — one
  physical batch in `board.md`. The in-Kodi check closed the same day: the user reports the remote
  works perfectly, OK selects.

## 11. Housekeeping — evidence in-repo, backups together (2026-09-29)

- The host reboot wiped `/tmp/opencode/preserve/`: regenerable copies gone (the SSH key is live, BLE
  pairing never happened, root password is per-boot, Wi-Fi is the user's own) — `forensics.tar`
  lost, so the cause of the 09-27 zeroed logs stays ❓.
- IR capture rounds moved into `stock/mortal-t1/` (`ev9-*.log`) — §10's raw material, re-capturable
  only by pressing the remote again.
- Repo stays local (user decision). `backup/mortal-t1/` now holds the eMMC stock image, its flash
  log and `mortal-t1-unpushed.bundle` (every commit past `origin/main`); board.md's restore path
  updated.

## 12. First BLE bond — the user's keyboard (2026-09-29)

Not the bundled remote: the user's Samsung keyboard (`v04E8:7021`), exercised pair → bond → HID →
input before the remote's BLE round. End state `Paired/Bonded/Trusted/Connected: yes`, input node
live, typing confirmed by eye.

- Race: bluetoothctl commands inside the first ~3 s lose to bluetoothd ("Failed to register agent
  object") — `sleep 3` before `agent`.
- `Pairable: no` rejects pairing — `bluetoothctl pairable on`, verify with `show`.
- `bluetoothctl remove` empties bluetoothd's device cache: `devices` shows nothing while
  `btmgmt find` still sees the device — rediscover in-session (`scan on`) or parse the MAC out of
  `btmgmt find`.
- Two public identities seen, `…:00:10` and `…:00:11`: bond on `…:10` completed but the link dropped
  seconds after HID bind, twice (reason 1, cause ❓); remove + re-pair on the stronger `…:00:11`
  held.
- Cadence in one live session: `pair` → 8 s → `trust` → `connect` → 15 s → `info`.

## 13. First suspend cycle — remote power both ways (2026-09-29)

- 12:28: logind `Power key pressed short` → `PM: suspend entry (deep)`; second press →
  `PM: suspend exit` (same wall second — no RTC mid-sleep). `boot_id` unchanged (`a121946a…`),
  booted 10:48.
- Back up clean: SSH alive, `wlan0` re-associated `.49`, `aicwf_sdio_suspend exit`.
- Keyboard re-bound after resume (`input17`, `.0008`), typed by eye; LED suspend red, running blue.
- Short cycle only — watchdog-window suspend and BLE wake still ❓.

## 14. Cold power cycle — full unplug (2026-09-29)

- Power off → plug out → wait → plug in: new `boot_id` (`986f4ae9…`), booted 12:36:20.
- `systemd-analyze` 29.711 s (kernel 11.242 + userspace 18.469); power-on → kernel leg unmeasured,
  no serial attached.
- `date` sane after total power loss (fake-hwclock), `wlan0` `.49`, console at getty.
- Bond survived full power loss: keyboard typed at the login screen, `Connected: yes` on first SSH
  after.

## 15. Power-on rows reclassified — structural, not pending (2026-09-29)

- No power button on the PCB; the box self-boots the moment wall power returns, and with the plug
  out the IR receiver has no rail. Cold IR power-on and power-button cold boot cannot occur — row
  moved to ➖, batch bullets dropped (user-confirmed).
- Soft `poweroff` with the wall on stays ❓: the pending LED-off observation answers whether it
  latches; recovery is a wall cycle either way.

## 16. Bundled remote over BLE — paired, decoded, hwdb-corrected (2026-09-29)

- Pairing mode = hold ◀+▶ until the LED blinks (H313 recipe); a watcher script caught
  `18:24:39:34:F7:95` and ran agent/pair/trust/connect in one session —
  `Paired/Bonded/Trusted/ Connected: yes`, battery 76 %. Same `2B54:1600` model as the H313's
  handset.
- Anchored rounds, logs `stock/mortal-t1/bt-r*.log`: r1 mixed (18 presses, user order), r2 ordered
  23 buttons → full attribution, r4 micro-round (gear/source/mouse ×3) resolved the last three,
  r6/r7 empty and full respectively (two launch windows were missed before r7 — keep them long).
- Raw usages: seven came back `KEY_UNKNOWN` (source, LIVE TV, apps, the four app keys), the cog sent
  `c008f` → `KEY_GAMES`, X sent `c0040` → `KEY_MENU`; the mouse button emits **no event at all**
  over BLE (pointer `REL_*` flows regardless) — `hwdb` cannot fix silence.
- `firmware/mortal-t1/bt-remote.hwdb` — nine overrides from this unit's capture only. The H313's
  shipped file maps `c0040=backspace`; T1's `c0040` is the X button and T1's IR table says delete,
  so this board got `delete` — the shared-model trap `docs/remote-keymap.md` warns about, caught
  before deploy. H313's `700aa=reserved` not needed: T1's voice sends one usage per press.
- Deployed per the doc: tee → md5 matched → `systemd-hwdb update --strict` → query hit →
  `udevadm trigger --subsystem-match=input --action=change` → all nine `KEYBOARD_KEY_*` properties
  on the live node (a `/dev/input/bt-remote-consumer` symlink exists). Every override re-read off
  the handset in two identical rounds: setup, video_next, delete, tv, appselect, prog1–prog4.
- Mic: `arecord -l` empty — voice key reports `KEY_SEARCH`, audio rides the `0xfeb3` GATT service
  (same out-of-scope answer as the H313).
- Power over BLE = power over IR: `c0030` → `KEY_POWER` → logind suspend cycled twice today
  (13:55:49, probably IR fallback while pairing was still running; 14:05:18 BLE-confirmed from r1).
  Both woke on a power key; the wake transport is not distinguishable in logind and the BT input
  nodes drop during sleep — BLE wake row stays ❓.
- Node numbers shift on every reconnect (uhid 10–13 → 4/5/10/11; dongle 4–7 → 6/7/12/13) — names
  carry identity, not event numbers.
- Long press per mode (A4): over BLE a hold is one down/up pair, no repeats, same scancode (vol+
  held 1.3/1.6 s, OK held 1.6 s — `stock/mortal-t1/bt-longpress-consumer.log`). Over IR a hold is
  one instantaneous frame (vol+ 0.16 s, OK 0.18 s — `ir-longpress*.log`). Power is the one gesture
  that splits: BLE hold ~3 s → logind `Power key pressed long` → **reboot** (boot ended 14:49:40,
  `986f4ae9` → `849d593d`); IR hold → press and release arrive together → `pressed short` → suspend
  (14:55:28). Tap = suspend on both transports.
- Capture hazards, learned the hard way: the remote auto-sleeps after ~14 min idle (its wake press
  is swallowed by the reconnect), and a host `bluetoothctl disconnect` loses the race —
  auto-reconnect came in 60 s cold, 4 s warm. The only stable IR window is `bluetoothctl power off`.
  The first long-press round went to `/tmp` and died with the reboot; later captures went to `/root`
  and survived.

## 17. Batch B — long suspend, wake paths, poweroff LED (2026-09-29)

- **Long suspend beats the watchdog window**: `echo mem > /sys/power/state` at 15:26:25; real sleep
  segments 15:26:25→15:26:59 (34 s) and 15:26:59→15:29:38 (**159 s**) against the 89.5 s window
  (`2^(16+15)` @ 24 MHz). `boot_id` `849d593d` identical before/after, uptime continuous, no restart
  entries: deep sleep is sleep, not a hidden reboot. The board has no RTC — `rtcwake` fails
  (`/dev/rtc*` absent) and wall-clock stamps freeze across suspend, so timed wake does not exist and
  the sleeper must be woken by input or power cycle.
- **BLE wake ❌ — IR is the only wake path.** `ttyS2` (`ffa00000.serial`) `power/wakeup` was enabled
  before the test; afterwards `/sys/kernel/debug/wakeup_sources` shows `ttyS2` event count **0**,
  and the waker is `rockchip_pwm_remote`. The failure is structural: suspend drops the BLE link
  (uhid nodes removed, HOG reads fail on resume), so the remote cannot deliver anything over BLE
  while the box sleeps — covered-OK presses (IR blocked, per the test plan) produced no wake; both
  wakes came from aimed IR power presses. Couch rule: point the remote at the box to wake it, and
  prefer a non-power button — the 15:26:59 wake had its power press read post-resume and logind
  instantly re-suspended (the 15:29:38 wake did not).
- **Poweroff LED**: `systemctl poweroff` → LED red, then dark; soft-off stays off (no self-boot);
  unplug/replug cold-boots (new `bcd60fd6`). Dongle keys (A5) dropped by user decision — not a core
  accessory for the box.

## 18. USB bring-up — hub ceiling, 5 Gbps fault, BOS, uas (2026-09-29)

- The all-in-one dongle was caught by `lsusb -t` before any benchmark: two nested `214b:7260` hubs,
  `Product: USB2.0 HUB`, everything behind them at 480M with bus 2 empty — the dongle's own hub chip
  is the ceiling, not the port. The 2 TB "USB 3.0" SSD (`048d:1234`, SDK PSSD) produced no
  SuperSpeed event in three plugs (one watched live in `dmesg -w`) — USB2 path only, sticker or not.
- SanDisk 3.2 Gen1 125 GB (`0781:55b1`) is a real USB3 device. Plug 1: `usb 2-1: new SuperSpeed`,
  then setup-address timeouts, `error -71`, USB2 fallback, then `-110` descriptor timeouts on both
  speeds → `unable to enumerate`. Reseat: **SS enumerated three times (devices 5, 6, 9 —
  `usb-storage` bound, `sda` attached) and dropped 0.3–1.7 s later each time, always right after the
  first SCSI traffic**; after the fourth drop the device fell back to 480M and has been stable
  there. Traffic-correlated SS dropout = the 5 Gbps path fails under load. One device tested — a
  second would split drive-vs-port.
- BOS over the fallback (`lsusb -v`): `bcdUSB 2.10`, `SuperSpeed USB Device Capability`,
  `wSpeedsSupported 0x000e` = FS + HS + SS 5 Gbps — judged by BOS, straight in the socket, per
  `docs/board-validation.md`.
- `uas`: the SanDisk exposes one interface at `bInterfaceProtocol 0x50` (BOT); `usb-storage` binding
  is correct and `uas` (registered at boot) has nothing to bind. Row stays ❓.
- USB2 throughput, fixed fio params, read-only on the raw disk: seq 1M QD8 **16.0 MB/s**, rand 4K
  QD32 **2.2 MB/s**. The GEMBIRD reader path (all-in-one dongle) measured 5.4 / 5.5–5.6 MB/s
  write/read — card-limited — and passed the 512 M direct-I/O integrity round-trip after
  `drop_caches`: the card is clean, so run-1's corruption points at the slot/host path.
- Debugging lore: xhci debugfs `portsc` read `Connected Link:U0 PortSpeed:3` while dmesg had no
  SuperSpeed line at all — on this BSP kernel dmesg is the witness, not `portsc`.
- The JMicron enclosure (`152d:a583`, UAS) settled the port question. Session 1: SS enum after
  setup-address retries (`error -71`), `uas` bound at 5000M, then `uas_pre_reset: timed out` and
  `Read Capacity(16)/(10)` failed `ASC=0x44/ASCQ=0x81` → 0 B disk; the USB link itself held. Session
  2 (replug): enum clean, capacity OK (28131328 × 512 B, 4096-byte physical blocks), stable 5000M —
  fio seq 1M QD8 **343 MB/s**, rand 4K QD32 **44.1 MB/s** (read-only, fixed params).
- **The blue port is true USB 3.0**: 5000M on the `1d6b:0003` root hub, `uas` bound, BOS SuperSpeed
  capability, `fio` recorded. The SanDisk stick fell back to 480M in every session — device and port
  recorded as seen, no attribution.

## 19. D closed — power meter dropped, no equipment (2026-09-29)

- User has no watt meter; `Draw metered` stays ❓ with the reason recorded. D's USB legs —
  throughput, integrity, card-vs-slot discriminator, USB 3 characterization — are all in §18.

## 20. Hardware decode to the panel — jellyfin-ffmpeg rkmpp → fbdev (2026-09-30)

Closing the gap the Kodi/mpv rows left: the VPU decodes (§ day-1 matrix) but no player on the box
linked rkmpp. Numbers in `board.md`.

- `jellyfin-ffmpeg7_7.1.4-3-trixie_arm64.deb`, `apt-get install --no-upgrade` — `Install:` line
  only, 0 upgraded. Bundles `librockchip_mpp.so.1` + `librga.so.2` in its own `lib/`, so the
  `/root/mpp-build` tree is not needed for playback; `-decoders | grep rkmpp` lists 10 decoders,
  `-filters | grep rk` the three RGA filters.
- Clips built on the host: 10 s `testsrc2`, 4K60 libx265 40M, 1080p60 libx264 20M; scp to `/root`.
- Stage-by-stage at 4K60 HEVC, `-f null` vs `-f fbdev`: decode **89 fps** (SW 13, 6.8×), + RGA 720p
  scale + `hwdownload` **56**, + fbdev write **46–48**. 1080p60 H.264 full path **108 fps**. CPU on
  the full path ≈1 core of 4 (`time`: 13.2 s wall, 13.3 s CPU).
- Connector was `disconnected` for the first runs (TV off) — writes to `/dev/fb0` complete rc=0
  regardless, so fps is measurable with no sink; the picture check waited for HPD (t=2640), then the
  full clip ran live at 46 fps, rc=0, 0 errors, human-confirmed on screen.
- The cost sits in `hwdownload` + the fbdev full-frame copy, not the decoder — same shape as the H96
  Max measured in `docs/mpp.md`. 4K60 realtime misses (48 < 60); 4K30 and 1080p60 clear it.
- Trivia: box `time` is the shell builtin (`/usr/bin/time` absent); first SSH after the TV came up
  timed out once while wlan0 sat at 2/3 packet loss, 101 ms RTT — it recovered on retry.

## 21. F — `reboot maskrom` proven, and the box boots off host VBUS (2026-09-30)

The `mode-maskrom` hunk was the last untested DT change and this unit's only maskrom entry (the
button beside HDMI is inert, §10). Rows in `board.md`, node in `dtb.md`.

- Prereqs: host `rkdeveloptool` 1.32 runs at user level (no sudo — first `ld` on an empty bus
  printed `not found any devices!`, not a permission error), `rk3528_spl_loader-mortal-t1.bin`
  present. SD stays in: BootROM halts before storage is read.
- Sequence per the single-5V rule: **PSU out first**, USB-A m-m cable box-blue-port ↔ host. The box
  **booted the full OS off host VBUS** — SSH back in ~30 s, uptime 0 min, wlan0 at `.49`. That was
  the open caveat; it is answered: VBUS alone runs it, network and all.
- Baseline `ld`: `not found any devices!` (OS mode enumerates nothing on the port). Then
  `reboot maskrom` over SSH — connection closed by remote host, and on the second poll:
  `DevNo=1 Vid=0x2207,Pid=0x350c,LocationID=204 Maskrom`. BootROM reachable in ~5 s, no button, no
  serial.
- Recovery as designed: cable out, PSU in, power cycle → new `boot_id`, root back on `mmcblk0` (SD),
  `mmcblk2` (eMMC) untouched. Stranding is real but costs one power cycle.
- Not attempted: `db` / `wl` pattern write — separate rows, G's restore covers the write path.

## 22. G — maskrom write/restore, SD → eMMC migration, eMMC boot (2026-09-30)

The storage criteria of done, one day: the maskrom `wl` path proven non-destructively and then for
real, the migration spliced byte-exact, the box booted from eMMC with the SD out. Rows in
`board.md`.

- Cable session (PSU out, VBUS in — the box boots the full OS off host VBUS): `reboot maskrom` →
  `ld` = `Maskrom` on the 2nd poll; `db` of `rk3528_spl_loader-mortal-t1.bin`; `rfi` = 15269888
  sectors = `blockdev --getsz` (Samsung, 7456 MB).
- Full-disk `wl 0` of `mortal-t1-eMMC-stock.img`: 7.8 GB in **6 m 48 s (19.2 MB/s)**, rc=0; full
  `rl` readback **3 m 48 s (34.3 MB/s)**, md5 `6537dc0b…` = the image. `rl` sector 64 (2 MB) md5
  `6a2f0b52…` = `factory_idbloader.bin`.
- Non-destructive `wl`: the only outside-partition gap is **LBA 34–63** (GPT entries → idbloader —
  present in the stock and the migrated layout alike). Original `c911a195…` → pattern written and
  read back `c78a33ab…` → original restored and read back `c911a195…`.
- Power cycle between phases failed dark (LED off, no boot) — the PSU was loose; reseated, fine.
- Migration: `armbian-install --target /dev/mmcblk2 --boot emmc --fs ext4 --yes`. That box's
  armbian-config 26.8.0-trunk.426 has 0 `DVKR` hits → `dd bs=1M count=10` zeroed sectors 0–20479,
  window included. GPT inherited (not msdos — the bare `plan` probe defaults to msdos, `install`
  inherits the source table), root from 16 MiB, rsync ~6 min, done 10:46:52. Target fstab +
  `armbianEnv.txt` point at the eMMC's own UUID `6c18175f…` (SD = `2f63de46…`). Bootloader is our
  `platform_install.sh`: factory idbloader into all 5 BootROM slots — the file is four identical 512
  K quarters, so 64–4159 came back byte-identical to stock — `uboot.itb` zeroed then written into
  both slots.
- Splice `dd if=window.bin of=/dev/mmcblk2 bs=512 seek=7168 conv=notrunc,fsync`: readback md5
  `a11247c7…` byte-identical; `DVKR`@7168 / `SSKR`@8192 tagged; `rk35xx-vendor-storage lan` =
  `00:1c:79:a1:71:92`.
- Boot-area diff vs the image (sector by sector, first 16 MiB + last 64): only sectors 0–5 (GPT),
  16384–24575 (`uboot.itb` A+B) and the backup GPT (`15269855–58`, `15269887`) differ. idbloader
  64–7167 and window 7168–16383 are identical to the backup.
- eMMC boot: SD out → new `boot_id 24f892fd…`, root `/dev/mmcblk2p1`, no `mmcblk0` in lsblk at all.
  Hotplug cycle in dmesg: insert 206 s, remove 575 s, reinsert 695 s — the card returns as `mmcblk1`
  while the SD is absent (numbering shifts, as `AGENTS.md` warns), root stayed on eMMC throughout.

## 23. `--pull` retargeted at the fork — the URL, not the mechanism (2026-10-03)

- §8's `unknown board 'mortal-t1'` rc=1 had a second cause beyond the T1 being unpushed:
  `rk35xx-update` line 43 hardcoded `REPO_URL=…/sormy/rk35xx-tvbox-armbian`, so `--pull` cloned a
  tree with no `firmware/mortal-t1/` regardless of what this repo held. The T1 was pushed to
  `enoshei-beep/rk35xx-tvbox-armbian` (local `main` = `8974fb1` = the fork's `main`, 125 commits).
- `REPO_URL` retargeted to the fork. Lines 49/59 `remote set-url origin "$REPO_URL"` re-point the
  clone on every pull — that mechanism is deliberate (`docs/h96max-h313/worklog.md`, rename
  readiness) and is unchanged; only the value was wrong.
- Affects all four boards: `--pull` now fetches this tree, so sibling boxes receive this repo's
  `firmware/<board>/` rather than upstream's. `rk35xx-deploy` never reads `REPO_URL` and is
  unaffected.
- Not yet run on a box at the time of writing — rc 0 from the box in §24.

## 24. On-box verification of §23, and the tooling that had vanished (2026-10-03)

- Box `mortal-t1` at `192.168.50.49`, root key auth. `/usr/local/share/rk35xx/repo` was an rsync
  tree from `rk35xx-deploy`, not a git checkout, so `--pull` takes the `rm -rf` + `clone` branch and
  the installed updater still carried sormy's URL. Snapshotted first:
  `/root/repo-rsync-20261003-094003.tar.gz` (32 MB).
- Installed updater vs repo copy: `diff` = line 43 only, no drift.
- `git ls-remote` from the box returned `deab340` before anything was deleted.
- `rk35xx-update --pull` → **rc 0**; origin `enoshei-beep/rk35xx-tvbox-armbian`, HEAD `deab340`;
  `board.dtb` `8e11307b…` unchanged → no reboot, uptime continuous.
- `[2/6]` logged `dkms: not found` and continued — **`dkms` was not installed**: `dpkg-query` → _no
  packages found matching dkms_, no `/usr/sbin/dkms`, `PATH` normal. The `.ko` carries a 09-29 10:47
  mtime. `dpkg.log` opens only at 10-02 21:04 and `apt/history.log` has no `dkms` line — neither
  covers the earlier state, so _absent from the log_ says nothing about when it went. §25 is that
  window.
- Found with it: `v4l2loopback` had no package, no `/usr/src` tree, no `.ko`, no
  `/etc/modules-load.d/v4l2loopback.conf` — nothing in `dpkg` either, while `board.md` claimed it
  loaded every boot.
- IR was unaffected throughout: `event9` = `ffa90030.pwm`, `platform-ffa90030.pwm-event` symlink,
  IRQ 27 present, module loaded.
- Both fixes `--no-upgrade`, 0 upgraded:
  - `apt-get install --no-upgrade dkms` → 3.2.2-1~deb13u1, sole install, no dependencies.
  - `apt-get install --no-upgrade v4l2loopback-dkms` → 0.15.0-2, built for `6.1.115-vendor-rk35xx`.
- `rk35xx-update --pull --no-reboot` → rc 0; `[2/6]` now runs the full
  `dkms add → build → install → depmod`. `dkms status` = both modules `installed`; `.ko` rebuilt
  10-03 09:49.
- `/etc/modules-load.d/v4l2loopback.conf` recreated — §8's box-side file, in no payload.
- `/dev/video0` is the loopback's dummy node as in §8; `/dev/mpp_service` (240, 0) untouched, so the
  §8 codec matrix stands. §20's playback path does not — `jellyfin-ffmpeg7` is gone, §25.
- Both update paths re-verified: `rk35xx-deploy` (§8) and `rk35xx-update --pull` (here).
- Not verified: an actual IR keypress — IRQ 27 sat at 7 across samples taken with no key held.

## 25. The window §24 could not see — an undocumented reinstall, two packages gone (2026-10-03)

- Root fs `/dev/mmcblk2p1`, UUID `ea63219a…`, **`Filesystem created: Thu Oct 1 13:35:12 2026`** —
  not §22's eMMC migration (`6c18175f…`, 09-30) and not the SD (`2f63de46…`). An Oct 1 install with
  no worklog entry; this is the first record of it.
- `lsblk -d` lists `mmcblk2`, `mmcblk2boot0/1` and zram only — no SD. Boots from eMMC, as §22 left
  it.
- `dpkg.log` opens `2026-10-02 21:04:16 startup packages remove` — 38 removals, headed by
  `jellyfin-ffmpeg7` and `kodi-rockchip-gbm` with their dependency trees (avahi, bluetooth, mariadb,
  samba, libinput, wacom …).
- Neither is on the box: `dpkg -l | grep -Ei "kodi|jellyfin"` → none, no `kodi` on `PATH`,
  `/usr/lib/jellyfin-ffmpeg/ffmpeg` → no such file. §9's Debian `kodi` and §20's `jellyfin-ffmpeg7`
  both belonged to the pre-Oct-1 install.
- Consequence: `board.md` §9 (Kodi GBM on screen) and §20 (46–48 fps 4K60 to fbdev) are evidence
  about software the box no longer carries. Reinstall the packages or restate the rows — open.
