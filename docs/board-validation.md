# Board validation — criteria of done

The gate a board passes before it ships. Every line gets **✅ verified · 🟡 likely (a proven
mechanism backs it, nothing indicates a problem) · ❓ never tested · ❌ broken · ➖ not on this
box**, numbers and reasons in `docs/<board>/board.md`. Blank is not an answer; nothing is inherited
from a sibling board.

Run every unattended check before asking the human for anything, then hand them one batched list.
Risk order: SDIO Wi-Fi, the Ethernet PHY, the video codec, anything the DTB touched.

## System

- [ ] `systemd-analyze` recorded; `blame` explains every second and waits on no absent hardware
- [ ] Boot time at or under the board's recorded figure, on the **second** boot
- [ ] `dmesg` accounted for line by line — nothing repeated at any level; tolerated lines named in
      `board.md` with the reason
- [ ] `hostname` and `/usr/lib/tvb/board-{id,name,pcb}` correct
- [ ] `dpkg -l 'tvb-*-modules'`: every out-of-tree module installed, and present in `lsmod`
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
      idbloader and the U-Boot FIT differ
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
      `boards/<board>/factory_idbloader.bin` byte for byte
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
- [ ] Throughput idle **and** under 4-core load, both bands, **with the regulatory domain named** —
      it decides the no-IR channels and the power, so a figure without it is not comparable
- [ ] No latch — after the load stops, baseline returns at once or within 60 s
- [ ] MAC stable across three reboots, and again after eMMC migration
- [ ] MAC is **this unit's own** — from the Wi-Fi part's own eFUSE, not the SoC's id and not a
      constant in a shipped blob, which every board off the image would share. Check against a
      second unit, or against the blob: `od -A x -t x1 -j 4 -N 6 <eeprom>.bin` returning the running
      address means it came from the file
- [ ] Shipped firmware is named for its scope: a generic image takes no board suffix, a per-board
      file — EEPROM, calibration, NVRAM — takes one. An unsuffixed per-board blob is how a shared
      MAC ships in the first place
- [ ] With no region code set, `iw dev wlan0 scan` still finds networks — an empty channel list
      looks healthy in `iw list`
- [ ] `iw reg set <country>` returns, and the box still answers afterwards

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
- [ ] **4K60 video on screen**, not only a 4K desktop: the video plane can fail to read 3840x2160
      NV12 at 60 Hz while the decoder keeps up
- [ ] A PC monitor too — the pixel-clock quirk bites there, not on TVs
- [ ] A picture that blinks or drops: swap the HDMI cable before suspecting the tree
- [ ] HDMI audio (`aplay -D hdmi:…`), and it is the default sink
- [ ] HDMI audio beyond stereo: multichannel LPCM, and AC3/DTS passed through to a receiver
- [ ] HDR: an HDR10 video switches the TV to HDR — the infoframe and 10-bit output, not the decode
- [ ] CEC: `cec-ctl` finds the adapter with a physical address from the EDID; the TV remote reaches
      the box, and `cec-ctl -S` lists the TV
- [ ] DDC/CI: `ddcutil -b <bus> getvcp 10` reads a PC monitor's brightness, and `setvcp 10` moves it
- [ ] HDMI hotplug re-detects, with no blank screen afterwards
- [ ] AV jack: composite video **and** analog audio
- [ ] GPU renders, fps recorded — **this one needs no screen**, see below
- [ ] GPU renders **on screen** — use `kmscube`. It honours the connector's `preferred` mode and
      renders correctly at 4K

**The GPU check needs no display:** EGL on GBM with `EGL_KHR_surfaceless_context` renders to an FBO
on the render node; `glReadPixels` on a known triangle is the pass, the loop's timing the fill rate.
Choose the config without `EGL_SURFACE_TYPE`, run in the `render` group, and record
`GL_MAX_TEXTURE_SIZE`.

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

## Remote keymap

- [ ] `docs/remote-keymap.md`'s checklist passes once per transport, IR and BLE, scancodes recorded
- [ ] Any `hwdb` override compiled and the keycode re-read off the handset — a passing
      `systemd-hwdb query` proves the match, not the remap

## Device tree

- [ ] No node claims hardware the board lacks. A factory tree is a reference design: every
      `status = "okay"` is **its** claim, not this PCB's
- [ ] Each ghost disabled, its `board.patch` hunk marked **`NOT FITTED -`** with the evidence, so a
      reader can tell a correction from a change we chose
- [ ] Every other hunk carries its own rationale — `NOT FITTED` describes the board, the rest our
      stack
- [ ] After any tree change, re-check the nodes you did **not** touch are still `okay` — eMMC first

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

- `ssh` is not a throughput test: its encryption is CPU load. Use `iperf3` or `nc`.
- Measure the **second** boot; the first spends a minute on resize and first-run setup.
- Judge a `dmesg` line by what it tells the reader, not its level: `-l err,warn` hid 793 of the
  R69's 914 lines. Demoting a `dev_err` to `dev_dbg` hides it rather than fixing it.
- `stock/<board>/dmesg.txt` is a baseline only if it covers early boot; a wrapped ring passes
  everything.
- **The `fio` parameters are fixed**, so every board and medium compare. Record decimal MB/s
  (`bw=371MiB/s` is 389 MB/s), and idle a few seconds between phases: a drive throttles.

  ```sh
  fio --name=seq  --filename=<file> --rw=read|write         --bs=1M --size=1G   \
      --direct=1 --ioengine=libaio --iodepth=8  --numjobs=1 --runtime=30 --time_based
  fio --name=rand --filename=<file> --rw=randread|randwrite --bs=4k --size=512M \
      --direct=1 --ioengine=libaio --iodepth=32 --numjobs=1 --runtime=30 --time_based
  ```

- **On a 4K TV use `kmscube`, not `glmark2-es2-drm`:** the latter picks the largest-area mode, DCI
  4K, and renders onto a black screen; `docs/hdmi-edid-override.md` gets comparable numbers anyway.
- `glmark2-es2-drm` needs a VT and a free display: `Failed to become DRM master` usually means an
  earlier run holds `/dev/dri/card0`. `fuser -v /dev/dri/card0`, `pkill -9 -f glmark2`, then
  `openvt -s -w -- sh -c 'glmark2-es2-drm > /tmp/gl.log 2>&1'`.
- Anything driving the screen from a unit needs its stdin held open: `sleep 60 | kmscube`.
- Codec tests run as a **normal user**: the nodes ship `0600`, and root hides a missing udev rule.
- **Ten warm reboots, not one:** a `dwmmc` controller can fail its first init after `reboot` with
  `-110` and never recover, losing the SD root or wedging SDIO Wi-Fi; a cold cycle clears it.
- **Reloading a module you are connected through:** one detached script that unloads, checks and
  reloads, so a dropped connection cannot strand the box.
- A boot that grew is the cheapest signal: a unit waiting on absent hardware, a getty retrying a
  tty, a first-boot script never marked done, DHCP on an unplugged interface.

## Proving something is absent

- **Silence is not absence.** Disabling a node needs a positive signal: a driver error
  (`phy_poll_reset failed: -110`), a probe reading nothing
  (`unrecognized JEDEC id bytes: 00, 00, 00`), or vendor docs omitting it. `iw` lives in `/sbin`,
  off a non-login ssh `PATH`.
- **A silent IR node is ambiguous:** the driver registers with no receiver fitted, and is silent too
  when the remote matches no usercode table. A known-good receiver separates the two.
- **A capability measured before a boot stage was replaced** says nothing after it: maskrom through
  `Loader` existed only because the factory U-Boot served rockusb.

## Network under load

- Worth investigating: a >20% drop, latency in the hundreds of ms, retries climbing in
  `iw dev wlan0 station dump`, driver errors.
- A slowdown under load is contention; a link that does not return is a **latch**. Re-measure at
  once and after 60 s idle, and record which rung clears it: reassociate, reload, reboot.
- Check where interrupts land, `grep -E "mmc|sdio|eth|gmac|dwmac" /proc/interrupts`, then, cheapest
  first: `smp_affinity`, `rps_cpus`, the driver's bus-thread priorities. Each ships as board data
  with its measurement.

## MAC addresses

**Order of truth, best first.** Random is not a step; it is the bug.

1. **The printed label**, with vendor storage as its readable copy.
2. **The eFUSE on the chip that carries the interface.**
3. **Derived from that same chip's id.**
4. **Derived from the SoC's id**, only for an interface with no id of its own.

- Ethernet starts at 1, a radio on its own chip at 2. Sourcing across that is the fault to catch.
  Never a rootfs file, a rename-after-the-fact unit, or a constant every board shares.
- A moving IP after a reboot means an unpinned MAC. Compare `/sys/class/net/*/address` across three
  boots, and against the sticker.
- `dwmac-rk` takes any valid address: mainline U-Boot alone derives one from the OTP `cpuid#`, step
  4; ours reads `LAN_MAC` from vendor storage, `patches/u-boot/README.md`.
- `LAN_MAC` has stale copies; the label settles which is live. `WIFI_MAC` and `BT_MAC` are
  unpopulated on every board measured here, so a radio is checked against a second unit or the blob.
- A derived address sets the locally-administered bit, `0x02` of the first octet; one read from
  vendor storage stays as it is.
- A wandering `BD_ADDR` invalidates every pairing on every boot, silently.

## Power

- No RTC on this family, so no `rtcwake`; never suspend a box remotely.
- **Wake-on-LAN cannot work** with an integrated PHY: deep suspend powers it down. ❌ on the R69
  with `ethtool -s end0 wol g`, `power/wakeup`, `RKPM_GMAC_WKUP_EN`.
- **Off costs more than suspend:** `rockchip,virtual-poweroff` parks the SoC with the rails up.
  Prefer suspend; cutting a rail at poweroff splits one behaviour across layers.
- Meter the bare board: a USB stick and HDMI moved every R69 figure by tenths of a watt. A reading
  with peripherals is its own row, naming them.

## Recovery

- The watchdog's reset keeps ramoops in `/var/lib/systemd/pstore/`; a cold cycle loses it. It cannot
  be disarmed, so a board that hangs early loops: `docs/watchdog.md`.
- Serial is prospective: attach it, then reproduce.
