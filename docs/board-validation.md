# Board validation — criteria of done

The gate a board passes before it ships. Every line gets **✅ verified · 🟡 likely (a proven
mechanism backs it, nothing indicates a problem) · ❓ never tested · ❌ broken · ➖ not on this
box**, numbers and reasons in `docs/<board>/board.md`. Blank is not an answer; nothing is inherited
from a sibling board.

Run every unattended check before asking the human for anything, then hand them one batched list.
Risk order: SDIO Wi-Fi, the Ethernet PHY, the video codec, anything the DTB touched.

Everything up to **Overlay mode only** applies to any board; that section assumes this repo's
payload and an upstreamed board skips it.

## System

- [ ] `systemd-analyze` recorded; `blame` explains every second and waits on no absent hardware
- [ ] Boot time at or under the board's recorded figure, on the **second** boot
- [ ] `dmesg` accounted for line by line — nothing repeated at any level; tolerated lines named in
      `board.md` with the reason
- [ ] `hostname` and `BOARD_NAME` in `/etc/armbian-release` correct
- [ ] `dkms status`: every module `installed`, and present in `lsmod`
- [ ] Ten warm reboots in a row, and after each one **every device still works** — root mounts, the
      SD enumerates, `wlan0` associates, `hci0` is up, IR responds. Coming back up is not the test
- [ ] `free -m` matches the advertised RAM; `stress-ng --vm --verify` clean
- [ ] `/dev/watchdog` exists, systemd took it, `wdctl` then reports it busy
- [ ] The granted timeout is the **largest** step the watchdog clock allows, not the first one that
      works — `journalctl -b | grep "Watchdog running with"` against `2^(16+TOP)/clk`
- [ ] `board.md` carries identity, on-disk names, measured numbers and known gaps; `worklog.md` was
      written as the work happened; the README lists the board

## CPU, thermal, power

- [ ] `scaling_available_frequencies` matches the **factory** OPP table
- [ ] 5 min 4-core `stress-ng`: idle and peak against `trip_point_*_temp`, no throttling
- [ ] Draw metered at idle, suspended and off — **bare board, no peripherals connected**
- [ ] `PM: suspend entry (deep)` in dmesg, and `deep` bracketed in `/sys/power/mem_sleep`
- [ ] Suspend, resume on the remote, and it **stays** up — no logind double-fire
- [ ] Suspend for **longer than the watchdog window** and resume: same `boot_id`, not a cold boot
- [ ] Same with the remote in BLE mode: it reconnects after resume and still drives the box, and
      **wakes it** — BLE wake needs the BT driver to set `hdev->wakeup`, or the controller is torn
      down at suspend and only IR can wake the box
- [ ] Cold-boot time from off, timed
- [ ] RTC present and keeping time, or its absence recorded

## Storage

- [ ] eMMC: `fio` sequential + random 4K, direct I/O, the same parameters as every other board
- [ ] SD: enumerates, hotplug insert **and** remove, `fio` recorded
- [ ] Boots from eMMC on its own loader pair — `dd` sectors 64 and 16384
- [ ] After migration, sectors 7168–16383 are byte-identical to the backup; only the GPT, the
      idbloader and `uboot.itb` differ
- [ ] `DVKR` at sector 7168 and `SSKR` at 8192 still tagged; `LAN_MAC` still the sticker address
- [ ] Maskrom proven **before** it is needed — recovery button at power-on, `rkdeveloptool ld`
      reports `Maskrom`. **Entry is not recovery**: `db`, `rl` and a verified `wl` are a separate
      claim, and a board that only enumerates has not been shown to be restorable
- [ ] Proven again **on our U-Boot**, not only the factory one. Replacing slot A can remove the
      route that reached it: a board whose only path was `Loader` → `rd 3` loses it, because
      `Loader` is the factory U-Boot serving rockusb and ours serves no USB. **Mandatory on a board
      with no SD slot** — it is the only way back
- [ ] `db` loads the board's own loader, and `rfi` reports the true sector count
- [ ] `rl` verified against a known range — a read of sector 64 must match
      `firmware/<board>/factory_idbloader.bin` byte for byte
- [ ] `wl` verified **non-destructively**: write a pattern to empty space outside the partitions,
      read it back, restore the original, confirm the region is as it was
- [ ] **A full-disk read in one pass**, or the chunk count and stall point it needed. A board whose
      factory tree downclocks the eMMC is the one to expect trouble from
- [ ] **A full-disk write**, same question — a stalled write leaves the box unbootable, so this is
      the claim that matters for restore
- [ ] Throughput for both recorded in `docs/<board>/board.md`, with whether the rate held

## Ethernet

- [ ] Link speed and duplex as the hardware allows
- [ ] `readlink /sys/class/net/end0/phydev/driver` is the vendor PHY, not Generic
- [ ] Throughput idle **and** under 4-core load
- [ ] MAC matches the sticker, and survives reboots and eMMC migration
- [ ] Wake-on-LAN works, or `phy-is-integrated` is recorded as the reason it cannot

## Wi-Fi

- [ ] Associates on 2.4 GHz **and** 5 GHz; band and PHY rate from `iw dev wlan0 link`, or
      `wpa_cli -i wlan0 status` (`freq=`) where `iw` is not installed
- [ ] Throughput idle **and** under 4-core load, both bands
- [ ] No latch — after the load stops, baseline returns at once or within 60 s
- [ ] MAC stable across three reboots, and again after eMMC migration
- [ ] MAC is **this unit's own** — from the Wi-Fi part's own eFUSE, not the SoC's id and not a
      constant in a shipped blob, which every board off the image would share. Check against a
      second unit, or against the blob: `od -A x -t x1 -j 4 -N 6 <eeprom>.bin` returning the running
      address means it came from the file
- [ ] Shipped firmware is named for its scope: a generic image takes no board suffix, a per-board
      file — EEPROM, calibration, NVRAM — takes one. An unsuffixed per-board blob is how a shared
      MAC ships in the first place

## Bluetooth

- [ ] `hci0` `UP RUNNING`, `errors:0`, not rfkill-blocked on a fresh image
- [ ] `btmgmt find` returns devices
- [ ] `BD_ADDR` identical across three reboots, and **unique to the unit** on the same terms as the
      Wi-Fi address, derived from the Bluetooth part itself. On a combo part the two usually differ
      by one, which is a quick check that both came from the same place
- [ ] The bundled remote pairs, works, and the pairing survives a reboot
- [ ] A2DP to a speaker, or recorded as untested

## Display

- [ ] Picture on a real TV at native resolution; `modetest -c` mode list sane, EDID parses
- [ ] Switch modes with `modetest -M rockchip -s <conn>:<WxH>-<hz>` rather than rebooting — it is
      all runtime. Keep its stdin open (`sleep 60 | modetest …`) or it exits at once and the mode
      reverts before you can look
- [ ] **Every resolution class drives the panel: 1080p, 1440p/2K and 4K** — test all three, they
      fail independently. A width-limited line buffer looks fine at 1080p and fills the right of the
      screen with garbage at 4K, and refresh rate does not change it (4K30 fails exactly like 4K60,
      because the limit is width, not bandwidth). The damage scales with width: a 3840 panel lost
      ~half, a 2256 monitor ~30%
- [ ] If a resolution is broken, check `esmart_lb_mode` on the VOP node before anything else — the
      factory value `03` is `VOP3_ESMART_2K_2K_2K_2K_MODE` (every window 2K) and must be `02`
      (`VOP3_ESMART_4K_2K_2K_MODE`) for the primary plane to reach 4K
- [ ] A PC monitor too — the pixel-clock quirk bites there, not on TVs
- [ ] HDMI audio (`aplay -D hdmi:…`), and it is the default sink
- [ ] CEC: `cec-ctl` finds the adapter, the TV remote reaches the box, `cec-client` sees traffic
- [ ] HDMI hotplug re-detects, with no blank screen afterwards
- [ ] AV jack: composite video **and** analog audio
- [ ] GPU renders, fps recorded — **this one needs no screen**, see below
- [ ] GPU renders **on screen** — use `kmscube`. It honours the connector's `preferred` mode and
      renders correctly at 4K

**The GPU check does not need a display.** Debian's `glmark2-es2` is the X11 build and `kmscube`
needs a connected connector, which would strand the whole row behind a TV. EGL on the GBM platform
plus `EGL_KHR_surfaceless_context` renders to an FBO on the render node instead — `glReadPixels` on
a known triangle is the pass/fail, and timing the loop gives the fill rate. Two traps: choose the
config **without** `EGL_SURFACE_TYPE`, since GBM exposes window configs and asking for
`EGL_PBUFFER_BIT` fails; and the user needs the `render` group. Record `GL_MAX_TEXTURE_SIZE` while
you are there — on Mali-450 it is 4096, which caps what the GPU can do with 8K the VPU decodes
happily.

## Video codec

Test every cell at **720p, 1080p, 4K and 8K** — both surprises this repo found were at the extremes.

- [ ] MPP names the SoC — `match chip name: …`, not `use default chip info`
- [ ] The matrix below filled, as a normal user, fps recorded
- [ ] A real 4K HEVC file plays smooth and in sync with the CPU near idle

| Format                        | Decode | Encode | Pass means                                 |
| ----------------------------- | :----: | :----: | ------------------------------------------ |
| H.264 · HEVC · MJPEG          |   ✔    |   ✔    | the encode **decodes back**, not just >0 B |
| VP9 · AVS2                    |   ✔    |   —    | VP9 also settles `rk3528a` vs `rk3528`     |
| MPEG-2 · MPEG-4 · H.263 · VP8 |   ✔    |   —    | legacy VPU2 block, ≤1080p                  |
| AVS · AVS+                    |   ✔    |   —    | 🟡 is honest when no clip exists           |
| AV1                           |   ➖   |   ➖   | absent — record MPP's refusal              |

## USB

- [ ] `lsusb -t` speeds read **before** benchmarking — a USB 2.0 hub caps everything behind it
- [ ] USB 3 judged by the BOS `SuperSpeed USB Device Capability`, not `bcdUSB` (a fallen-back USB 3
      device reports `2.10`), and with the device plugged straight into the socket
- [ ] USB 2: enumerates at `480M`, throughput recorded
- [ ] USB 3: negotiates `5000M`, `uas` bound not BOT, `fio` sequential + random 4K
- [ ] Every port individually — they are not interchangeable
- [ ] Hotplug in and out on each, no dmesg complaints

## IR, buttons, LEDs

- [ ] IR receiver: an input node exists, and its IRQ in `/proc/interrupts` counts up while the
      remote is pressed
- [ ] IR-extender jack, if the board has one
- [ ] Power on the remote cold-boots the box from off
- [ ] Long press tested in the mode the remote is actually in — IR or BLE
- [ ] Toothpick/recovery button registers on the `adc-keys` node
- [ ] LED polarity confirmed by eye: running, suspended, off

## Remote keymap — run this once per transport

IR and BLE are two independent keymaps in one handset: IR is looked up in the `ir_keyN` table we
ship in `board.dts`, BLE is whatever HID usages the handset transmits. Neither predicts the other,
so passing one proves nothing about the other. `docs/remote-keymap.md` has the procedure and the
`hwdb` override.

Per transport, with `evtest` on `/dev/input/ir-remote` and on `/dev/input/bt-remote`:

- [ ] Every button produces an event, and its `MSC_SCAN` scancode is recorded alongside the keycode
- [ ] No button reports `KEY_UNKNOWN`
- [ ] No two buttons share a keycode
- [ ] The keycode matches the printed label — `KEY_MENU` on a ⌫ key is a fault, not a quirk
- [ ] Where the board has both transports, the two agree button for button
- [ ] The table, scancodes included, is recorded in `board.md`
- [ ] Any override shipped, compiled with `systemd-hwdb update`, and the keycode re-read off the
      handset — a passing `systemd-hwdb query` only proves the match, not the remap

## Device tree

- [ ] No node claims hardware the board lacks. A factory tree is a reference design: every
      `status = "okay"` is **its** claim, not this PCB's
- [ ] Each ghost disabled, its `board.patch` hunk marked **`NOT FITTED -`** with the evidence, so a
      reader can tell a correction from a change we chose
- [ ] Every other hunk carries its own rationale — upstream, `NOT FITTED` describes the board and
      the rest describes our stack
- [ ] `upstream/build.sh` reports `VERIFIED: native tree is content-identical to the patched tree`
- [ ] After any tree change, re-check the nodes you did **not** touch are still `okay` — eMMC first

## Overlay mode only

Skip on an upstreamed board — it takes kernel, DTB and identity from Armbian's own packages and
never reads `firmware/` or `/usr/local/share/*/`.

- [ ] Every installed file is `root:root` —
      `find / -xdev \( -uid <build-uid> -o -gid <build-gid> \)` returns nothing. e2tools copy the
      build host's ownership straight into the image
- [ ] Identity dir populated and correct: `board-id`, `board-name`, `board.dtb`, both loaders
- [ ] No other board's names under `/etc`, `/usr/local`, `/usr/lib/systemd`, `/usr/src`
- [ ] Loaders on disk match the identity dir — `dd` sectors 64 and 16384, md5 against
      `/usr/local/share/*/`
- [ ] Survives `apt full-upgrade`: `BOARD_NAME` intact, `linux-u-boot-*` held
- [ ] Both update paths work — `rk35xx-deploy` from a host, `rk35xx-update --pull` on the box
- [ ] Payload udev rules fire: anything a recipe names as `event<N>` has its `SYMLINK+=`
- [ ] The dtb-persist hook survives a kernel update — `/boot/dtb-*/rockchip/board.dtb` still matches
      `/usr/local/share/*/board.dtb`

## Needs the human — batch these into one trip

LED polarity (running, suspended, off) · every remote button under `evtest`, **once per transport**
· wake from off on the remote · suspend and resume, in IR mode **and** BLE mode · the
toothpick/recovery button, and on a slotless board that it reaches Maskrom **on our U-Boot** · HDMI
on a real TV and on a PC monitor · a real 4K HEVC file playing · a device in each USB port · SD
insert and remove · AV jack · power meter at idle / suspended / off, bare board · BT remote pairing
· eMMC migration, and the device name it asks to confirm.

---

# Caveats

## Measuring

- `ssh` is not a throughput test — its encryption is itself CPU load. Use `iperf3` or `nc`.
- Measure the **second** boot; the first legitimately spends a minute on resize and first-run setup.
- First boot compiles DKMS offline — allow ~4 minutes before calling it a failure.
- Level-filtering `dmesg` hides most of it: on the R69, 914 lines against 121 for `-l err,warn`.
  Judge a line by whether it tells the reader something, not by the level it was logged at —
  demoting a chatty `dev_err` to `dev_dbg` hides it rather than fixing it.
- `stock/<board>/dmesg.txt` is only a baseline if it covers early boot. The R69's starts at 523 s
  because the ring buffer had wrapped, so it classifies nothing and passes everything.
- **The `fio` parameters are fixed** — identical on every board and every medium, or the numbers do
  not compare. 1 MiB blocks at `iodepth=8` sequential, 4 KiB at `iodepth=32` random, always
  `--direct=1` so nothing is served from page cache:

  ```sh
  fio --name=seq  --filename=<file> --rw=read|write         --bs=1M --size=1G   \
      --direct=1 --ioengine=libaio --iodepth=8  --numjobs=1 --runtime=30 --time_based
  fio --name=rand --filename=<file> --rw=randread|randwrite --bs=4k --size=512M \
      --direct=1 --ioengine=libaio --iodepth=32 --numjobs=1 --runtime=30 --time_based
  ```

  Record decimal MB/s; `fio` reports KiB/s, so `bw=371MiB/s` is 389 MB/s. Let a drive idle a few
  seconds between phases — it throttles thermally, and a read taken straight after heavy writes
  under-reported by ~12%.

- **`glmark2-es2-drm` is the wrong tool on a 4K TV — use `kmscube`.** It picks the largest-area mode
  and ignores `DRM_MODE_TYPE_PREFERRED`, so on a TV advertising DCI 4K it renders a healthy frame
  rate onto a black screen. It cannot be steered. `docs/hdmi-edid-override.md` has the reasoning and
  the way to get comparable numbers anyway.
- `glmark2-es2-drm` also needs a VT and an **unoccupied** display. Over SSH it prints
  `Failed to become DRM master`, and so does `openvt` while an earlier run still holds
  `/dev/dri/card0` — that leftover is the usual cause, not permissions. `fuser -v /dev/dri/card0`,
  `pkill -9 -f glmark2`, then `openvt -s -w -- sh -c 'glmark2-es2-drm > /tmp/gl.log 2>&1'`.
- Anything driving the screen from a unit needs its **stdin held open** — `sleep 60 | kmscube` — or
  it reads EOF, exits immediately, and the mode reverts before you can look at it.
- Codec tests run as a **normal user** — the nodes ship `0600` and root hides a missing udev rule.
  Record fps: a silent fall back to software is the failure the matrix exists to catch.
- **A warm reboot is not a cold one, and one of them is not a test.** On this family a `dwmmc`
  controller can return `-110` on its first init after `reboot` and never recover — the SD root goes
  missing, or the SDIO Wi-Fi comes up wedged — while a cold power cycle always clears it. It is
  intermittent and per-driver (the `sdhci` eMMC has never done it), so reboot ten times and watch
  the root mount and `wlan0` specifically.
- A boot that has grown since the last measurement is the cheapest signal something is wrong. Usual
  causes: a unit waiting on absent hardware, a getty retrying a tty, a first-boot script that never
  marked itself done, DHCP on an unplugged interface, a DKMS rebuild meant to happen once.

## Proving something is absent

- **"Nothing enumerated" is not evidence of absence**, and neither is an empty command. Disabling a
  node needs a _positive_ signal: a driver error (`gmac0`: `phy_poll_reset failed: -110`), a probe
  reading nothing (`sfc`: `unrecognized JEDEC id bytes: 00, 00, 00`), or vendor docs that omit the
  feature. Without one, silence is equally explained by a cable, an adapter, or a tool that is not
  installed — empty `iw`/`hciconfig` output read as broken hardware here, and `iw` lives in `/sbin`,
  off a non-login ssh `PATH`.
- **A silent input device is ambiguous.** The IR driver registers whether or not a receiver is
  soldered, and is silent both when there is none and when the remote matches no DT usercode table.
  Drive a _known-good_ receiver with the same handset to separate the two.
- **A capability measured before a boot stage was replaced says nothing about the box after.**
  Maskrom was ✅ via `Loader` → `rd 3`, which existed only because the **factory** U-Boot served
  rockusb. Ours does not, so it went back to 🟡.

## Network under load

- A >20% drop, latency spikes into hundreds of ms, retries climbing in `iw dev wlan0 station dump`,
  or driver errors in `dmesg` are all worth investigating.
- A slowdown under load is contention and expected; a link that does not return afterwards is a
  **latch** and a defect. Stop the load, re-measure immediately and again after 60 s idle; `tx` far
  below `rx` at a strong signal is the signature. Record which rung clears it — reassociate, reload
  the module, reboot.
- Check where the interrupts land before reaching for anything else —
  `grep -E "mmc|sdio|eth|gmac|dwmac" /proc/interrupts`. Remedies, cheapest first: pin the IRQ
  (`/proc/irq/<n>/smp_affinity`), spread receive processing
  (`/sys/class/net/<if>/queues/rx-0/rps_cpus`), then raise the driver's own bus-thread priorities if
  it exposes them. Any of these is board data and ships in the payload with the measurement that
  justified it.

## MAC addresses

- A moving IP after a reboot means the MAC is not pinned, not DHCP. Compare
  `/sys/class/net/wlan0/address` across three boots.
- A valid but **wrong** address wins, and `dwmac-rk` takes any valid address it is handed. On these
  images that address comes from mainline's `rockchip_setup_macaddr()` — SHA256 of the OTP `cpuid#`,
  multicast cleared, LA bit set — because our U-Boot has no vendor-storage driver to read `LAN_MAC`
  with. Deterministic, so it will not churn; still step 4 on an interface that has a step 1. Check
  against the sticker, not against the last boot.
- **Order of truth, best first.** Each step is a weaker claim to being this unit's address, and the
  first two are assigned where the last two are only pseudo-unique:

  1. **The printed label**, with vendor storage as its readable copy — one path, not two.
  2. **The eFUSE on the chip that carries the interface.**
  3. **Derived from that same chip's id.**
  4. **Derived from the SoC's id** — last resort, and only for an interface with no id of its own.

  In practice Ethernet starts at 1 and a radio on its own chip starts at 2. Sourcing across that — a
  radio derived from the SoC while its eFUSE holds an address, an Ethernet address invented from a
  chip id — is the fault this section exists to catch. Random is not step 5; it is the bug. Never a
  rootfs file, never a rename-after-the-fact unit, never one constant shared by every board.

- **Step 1 can disagree with itself.** `LAN_MAC` appears in several copies at different versions —
  one board's two stale copies hold a locally-administered address the live copy does not. The label
  settles which is real, and matched the live copy on every board here.
- **Step 1 does not exist for a radio.** `WIFI_MAC` and `BT_MAC` are ids 2 and 4 in the schema and
  `rk35xx-vendor-storage` reads them, but they are unpopulated on every board measured here. 🟡 the
  label and vendor storage look like one path rather than two — no box seen here prints a Wi-Fi or
  Bluetooth address on its label either, so there is likely nothing assigned at manufacture to write
  into either place. So a radio is checked against a second unit or the blob, never the label.
- **A derived address — steps 3 and 4 — is locally administered**, bit `0x02` of the first octet.
  Neither `C4:2A:FE` nor `88:00:33` is a registered OUI, so deriving under them squats on space that
  is not ours; `rk35xx-mac-pin` sets the bit whatever `mac-oui` says. Addresses read from vendor
  storage are assigned and stay untouched.
- Bluetooth has the same requirement and a worse failure — a wandering `BD_ADDR` invalidates every
  pairing on every boot, and nothing in the logs says why.

## Power

- No RTC on this family, so no `rtcwake`.
- **Wake-on-LAN cannot work** with an integrated PHY (`phy-is-integrated`, no `phy-supply`): deep
  suspend powers it down, so nothing is left to see the magic packet. Exhausted on the R69 —
  `ethtool -s end0 wol g`, `power/wakeup: enabled`, `RKPM_GMAC_WKUP_EN` in `rockchip,wakeup-config`,
  ten magic packets, no wake. No Rockchip board in this BSP enables that wake bit either.
- **Never suspend a box remotely** — it is stranded until someone presses the remote.
- Expect off to cost **more** than suspend: with no PMIC, `rockchip,virtual-poweroff` parks the SoC
  with the rails up and DDR out of self-refresh, and drivers get `.shutdown()` not `.suspend()`. Do
  not fix that by dropping rails — suspend has a standard mechanism
  (`regulator-state-mem { regulator-off-in-suspend; }`, 130 Rockchip boards in-tree) and poweroff
  has none, so cutting a rail there splits one behaviour across layers. Prefer suspend.
- Meter the bare board — nothing in USB, no HDMI — or the numbers are not comparable between boards.
  A USB stick and HDMI moved every R69 figure by several tenths of a watt. Any measurement with
  peripherals attached is a separate row, labelled with what was plugged in.

## Recovery

- The watchdog is also the only hang recorder: its reset preserves ramoops to
  `/var/lib/systemd/pstore/`, and a cold power cycle loses it. It is unconditional and cannot be
  disarmed once armed, so a board that hangs early will loop — and its count carries across a soft
  reboot, which `watchdog.md` covers.
- Serial is a **prospective** instrument — attaching it to an already-hung box shows nothing,
  because the interesting output scrolled past. Attach it, then reproduce.
- `armbian-install` clears the first 16 MiB to lay down partitions. Upstream keeps sectors
  7168–16383 when it finds the `DVKR`/`SSKR` tags, and **that is the whole of the protection** —
  everything else there is overwritten and nothing restores it, so a full eMMC backup before any
  migration is mandatory.
