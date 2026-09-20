# A universal media stick

One stick, HDMI into whatever screen is to hand, everything else over Wi-Fi. Opened 2026-09-12.
Measured on the H96 Max 3518D; `docs/h96max-3518d/board.md` is what that **board** still needs, this
is what the **stack** needs. None of it is built yet.

## The capabilities, against what is measured

| Want                              | State | What backs it, or what is missing                           |
| --------------------------------- | :---: | ----------------------------------------------------------- |
| **Remote and TV**                 |       |                                                             |
| Bundled remote as an input device |  ✅   | BLE HID, paired and trusted, nine hwdb overrides            |
| TV's own remote drives the box    |  🟡   | `hdmi_cec_key` and `rc0` exist; never pressed a TV key      |
| Box drives the TV                 |  🟡   | transmit ✅; nothing sends One Touch Play or Standby        |
| Volume keys reach the TV          |  ❓   | CEC passthrough; today they would move ALSA instead         |
| **Playback**                      |       |                                                             |
| Kodi, from a home share           |  ❓   | decoders exist; no player here does zero-copy KMS           |
| YouTube on a Premium account      |  ❓   | VP9 ✅ 364 fps @1080p; addon login never tried              |
| Play from a USB stick             |  ✅   | 35.1 MB/s — if the stick is in before power                 |
| Hot-plugging that stick           |  ❌   | the 5 V rail cannot absorb the inrush; the box resets       |
| **Receiving a stream**            |       |                                                             |
| Google Cast reception             |  ➖   | closed and certification-gated; DIAL + Lounge is the subset |
| YouTube cast from a phone         |  ❓   | DIAL + Lounge is open; nothing here implements it           |
| DLNA / UPnP push                  |  ❓   | Kodi ships a renderer                                       |
| AirPlay audio                     |  ❓   | `shairport-sync` is packaged; HDMI audio ✅                 |
| AirPlay screen mirroring          |  ❓   | `uxplay` is the receiver; needs hardware H.264 in GStreamer |
| **Voice**                         |       |                                                             |
| Voice key                         |  ✅   | `c0221` → `KEY_SEARCH`, native                              |
| Voice **audio** off the handset   |  ❓   | vendor GATT service enumerated; no decoder written          |
| Recognition on the box            |  ❓   | no GPU compute path; nothing measured                       |
| **Network**                       |       |                                                             |
| Join a new Wi-Fi with no keyboard |  🟡   | radio does AP, and AP+STA together — no UI yet              |
| Hotel captive portal              |  ❓   | must be completed from the box's own MAC                    |
| VPN back home                     |  🟡   | `wireguard.ko` ships; throughput unmeasured                 |
| Plex / Jellyfin playback          |  ❓   | no ARM64 Plex client; a Kodi addon is the route             |
| PS5 Remote Play                   |  ❓   | decode ✅; the display path and the gamepad are the risk    |

## What decides the design

**The display path is the ceiling, and it is one fix.** 4K HEVC decodes at 51 fps and reaches the
screen at 27, because every frame is a full-frame copy into `/dev/fb0`. A DRM-prime frame handed
straight to a VOP2 overlay plane is what Kodi, AirPlay mirroring and Remote Play all need, and no
packaged player does it here. Five rows above move together the day it works.

**There is no `/dev/video*`.** The vendor kernel ships `CONFIG_ROCKCHIP_MPP_SERVICE`, so the decoder
speaks the MPP ABI on `/dev/mpp_service` and nothing binds `h264_v4l2m2m`. Any player must reach MPP
— through `jellyfin-ffmpeg7`, through GStreamer's rockchip elements, or not at all.

**Sleep and wake on the remote is parked.** BT is the only path, with no RTC and no IR receiver, and
the power key is `ignore` because a suspend can reach `Filesystems sync` and never finish freezing.
`research/seekwave-bt-wake/` holds the measured fixes and the fault that blocks them. Idle is under
0.5 W bare board, so standby buys the TV's input list, not power.

**No HD from the DRM services.** Widevine is L3 only, capping Netflix, Prime and Disney+ at SD/720p
— `docs/todo/rk35xx-optee-widevine.md`. Local files, Kodi, Jellyfin, Plex and YouTube are
unaffected.

**The 5 V rail bounds what can be plugged in.** One rail feeds the SoC and both USB ports. A powered
hub answers storage, port count and hot-plug at once, and frees USB-C — the only OTG port and the
only way into maskrom.

**2 GB of RAM, GLES 2.0, a hard 4096 px limit.** Chromium as the main UI is a poor bet, a player
needing GLES 3 will not run, and the GPU is fill-rate bound at 565 Mpix/s regardless of resolution,
so a 4K GUI costs four times a 1080p one for no gain.

**Half these features need mDNS on the same segment.** Cast, AirPlay, DLNA and a LAN Plex all die on
a hotel network with client isolation, where the VPN becomes the only path home.

## Display path — do this one first

**The copy is in the sink, not the decode API.** `hwdownload` pulls each frame out of device memory
and `-f fbdev` memcpys it back — two passes over 13.6 MB per frame. A V4L2 decoder feeding the same
sink would copy as much. Both APIs hand out a dmabuf fd; the fix for either is to import it as a DRM
framebuffer and page-flip it onto a plane, moving scale and YUV conversion into the display
controller.

**vp0 has the plane: `Cluster0-win0`.** AFBC, 8× scaling either way, YUV in hardware, so video never
reaches the fill-rate-bound GPU — neither the 4096 px texture cap nor the glmark2 figure applies.
Cluster windows are exempt from `esmart_lb_mode`, which matters because our `[02]` graft **drops
`Esmart1-win0` outright** rather than shrinking it. vp0's usable overlays are the two Cluster
windows; `docs/h96max-3518d/dtb.md` has the per-mode table.

**The plane is found: DRM plane 266.** ✅ `modetest -M rockchip -p`, 2026-09-13 — 14 planes, and
`Cluster0-win0` is the only vp0 overlay taking NV12 **and** NV15/NV20/NV30, so 8-bit and 10-bit both
land on it. Esmart1 is absent, as the `[02]` graft implies.

**Decode is 110 fps; the copy costs four fifths of it.** ✅ 2026-09-13: 480 frames of 4K HEVC
through `-hwaccel rkmpp -hwaccel_output_format drm_prime -f null -` at **110 fps**, against 27 fps
for the same clip down `hwdownload` + `fbdev`. 4K60 has headroom once nothing copies.

**The packaged GStreamer chain is stale.** ❌ `mppvideodec` and `kmssink` are installed, but
`libgstrockchipmpp.so` is **1.14.4 against a 1.26.2 core**, and every pipeline dies in
`gst_video_decoder_negotiate_default` with width 0 — H.264 and HEVC, parsed or via `decodebin`. MPP
opens each stream first and ffmpeg decodes at 110 fps, so it is the plugin, not the hardware.

**Then the player.** Kodi in **GBM mode** has a DRMPRIME renderer that hands the frame straight to a
plane, GUI still on lima. It needs an ffmpeg carrying `rkmpp`, and **Debian's Kodi links Debian's
ffmpeg, which has none** — `jellyfin-ffmpeg7` proves the decoders work here but is a separate
binary. That is the one unproven link. Two sources, neither tried:

- **Armbian's `rockchip-multimedia` repo**, packaging Kodi and GStreamer against the vendor MPP
  stack. ❓ whether it carries an RK3528 build and runs GBM on lima — the community builds around it
  target RK3588-class Valhall under panfork.
- **A `gst-rockchip` rebuilt against GStreamer 1.26**, turning the installed `mppvideodec ! kmssink`
  into the shortest proof of the path.

`mpv --vo=drm` is not a shortcut: it selected software decode and left the display with a mode set
and no scanout buffer.

## The V4L2 route — a config bool gates it, not the driver

The alternative to MPP, not the plan. Read off the Armbian vendor kernel (`rk-6.1-rkr5.1`, 6.1.115)
and its defconfig, 2026-09-13.

**`CONFIG_MEDIA_CONTROLLER_REQUEST_API` is the gate.** A promptless bool — only a `select` turns it
on, and the eight drivers that do are codec and test drivers, none enabled in
`linux-rk35xx-vendor.config`. With it off, `MEDIA_IOC_REQUEST_ALLOC` returns `-ENOTTY` and
`V4L2_BUF_CAP_SUPPORTS_REQUESTS` is never advertised, so userspace cannot get the request fd every
stateless decoder needs. ✅ absent from `/boot/config-6.1.115-vendor-rk35xx`, 2026-09-13, and that
file is a full config. `V4L2_H264`, `V4L2_VP9` and `VIDEO_ROCKCHIP_VDEC` are absent with it;
`MEDIA_CONTROLLER`, `VIDEO_DEV` and `V4L2_MEM2MEM_DEV` are `y`, arriving with camera and RGA.

**DKMS cannot lift that gate.** The `media_request_*` symbols are exported whatever the bool says,
so a module would link — but the gate is an `#ifdef` inside `mc.ko` and `videobuf2-v4l2.ko`, and no
out-of-tree module reaches another module's compilation unit. **The fix is one symbol in Armbian's
config:** `CONFIG_VIDEO_ROCKCHIP_VDEC=m` selects the request API, `V4L2_H264` and `V4L2_VP9`
together, and the staging driver it enables matches only `rockchip,rk3399-vdec`, so it never binds
here.

**The port is DKMS-shaped and the variant delta is small.** RK3528 is **VDPU382**; mainline carries
its neighbours VDPU381 (RK3588) and VDPU383 (RK3576), not this one. In MPP the per-SoC delta is
`hw_info` plus `hw_ops`, and RK3528 shares `vdpu382`'s table, `trans_info` and `dev_ops` with
RK3562. The SoC-name half is free: `board.patch` already appends `rockchip,rk3528a`.

**6.1's uAPI covers H.264 and VP9, and stops short of HEVC.** The stateless H.264, HEVC and VP9
controls are all in `v4l2-controls.h` here; AV1's are absent and irrelevant. The catch is that the
VDPU381/383 merge **extended** the stateless HEVC uAPI with two controls that do not exist in 6.1
and cannot be added from a module — the control core validates compound types. H.264 first.

**It costs the MPP path and buys compatibility, not speed.** `CONFIG_ROCKCHIP_MPP_RKVDEC2=y` claims
`rockchip,rkv-decoder-rk3528`, and one block takes one driver (encode is a separate node and
survives). MPP already exports DRM-prime frames; the 27 fps is the blit after it. What V4L2 wins is
stock GStreamer, Kodi and Chromium instead of vendor-patched builds.

## CEC — both halves are one evening

Present and verified: `/dev/cec0`, `dw-hdmi-cec`, CEC 2.0 with `Transmit`, `Remote Control Support`
and `Passthrough`, physical address 3.0.0.0 from the EDID, logical address 8 as Playback 2, and a
message transmitted. Nothing consumes any of it.

- **Box → TV:** One Touch Play at start (`<Image View On>`, `<Active Source>`), `<Standby>` at
  shutdown. `cec-ctl` does both by hand first.
- **TV → box:** press a key on the **TV's** remote and watch `hdmi_cec_key`. The adapter advertises
  Remote Control Support, so it should already emit keys.
- **Volume:** the stick's volume keys should reach the TV as `<User Control Pressed>`, not move the
  box's mixer. Kodi does this through libCEC; mapping is `docs/remote-keymap.md` territory after.

**The handset fights CEC when the BLE link drops.** It falls back to IR, and a TV in the room was
observed acting on power and OK — a CEC standby and an IR power press can undo each other.

## Kodi and YouTube

Kodi is the fit: hardware decode, a UI a D-pad can drive, USB browsing, a UPnP renderer, and addons
for Plex, Jellyfin and YouTube in one process. Unknown is whether it renders here at all.

- GUI at 1080p, 4K left to the video plane — ❓ whether Kodi's GBM renderer splits it that way on
  this VOP.
- **YouTube:** the addon signs in with a personal account, Premium removes the ads. Pin it to VP9 —
  AV1 has no hardware here and software AV1 is 40.6 fps with all four cores pegged.
- **From home:** a 4K remux is ~80 Mbit/s against 185–206 Mbit/s measured on 5 GHz. It fits, but the
  box roams to 2.4 GHz on its own, where it would not. ❓ no sustained run yet.

## Receiving a stream from a phone — evaluate the receivers

Open receiver projects, none of them run here yet. All of them need mDNS on the same segment.

- **AirPlay audio: `shairport-sync`** into `plughw:0,0`, the only playback device here. Packaged,
  and the cheapest thing on this list to prove.
- **AirPlay mirroring: `uxplay`.** An open AirPlay 2 receiver that decodes through GStreamer and
  hands off to a sink, so it inherits the `mppvideodec` / `kmssink` chain the display section has to
  fix anyway. ❓ whether it builds here and whether it can be pointed at the hardware decoder rather
  than `avdec_h264` — software H.264 is 14 fps, which is not a fallback.
- **Google Cast reception has no open receiver.** The protocol is closed and the receiver side is
  certification-gated, so a full Cast target is unreachable however much work goes in.
- **The open subset is DIAL plus the YouTube Lounge protocol**, which is what the phone's YouTube
  app actually speaks, and which has working third-party implementations. ❓ whether the Kodi
  addon's pairing path covers it or a separate receiver is needed. It buys YouTube casting only — no
  Netflix, no Spotify, no Android screen mirroring.
- **Android screen mirroring** belongs to Cast and goes with it. The open substitute is Miracast
  over Wi-Fi Direct — ❓ whether this radio and `wpa_supplicant` support P2P at all, which
  `iw phy phy0 info` answers alongside the AP question below.

## Voice — two projects, not one

The key works; the audio does not leave the handset. It rides the Android TV voice GATT service
(`ab5e0001…`, with `ab5e0002` write/read/notify and `ab5e0003`/`0004` notify), enumerated in
`research/seekwave-bt-wake/README.md`.

- **A BlueZ client** that negotiates capability and reassembles the stream. ❓ which codec this
  handset negotiates — that decides how much CPU the next step has left.
- **Recognition on the box.** Mali-450 has no compute API, so this is four A53s at 1416 MHz and 2
  GB. `vosk` with a small model suits a fixed command grammar, `whisper.cpp` with `tiny` suits free
  speech. The deciding number is CPU-seconds per second of audio on a 3 s utterance.

**Do not blind-probe the `0xae00` / `0xae40` vendor pairs.** They have the shape of an OTA control
point, and this is the only input device the board has.

## Network — the part that makes it universal

- **Does this radio do AP mode, and AP+STA at once?** `iw phy phy0 info` answers both under
  supported interface modes and valid interface combinations. Onboarding without a keyboard depends
  on it, so ask first.
- **Wi-Fi and Bluetooth share one antenna by TDD.** An AP, a station and a BLE remote on one antenna
  is the worst case, and the cost is unmeasured.
- **The captive portal has to be satisfied from the box's own MAC.** Either a minimal browser
  on-screen driven by the remote, or register a phone on the portal and give `wlan0` that address
  afterwards — no browser, no UI, and the MAC machinery exists (`docs/todo/rk35xx-mac-pinning.md`).
  ❓ whether portals bind to the MAC alone.

## VPN, Plex, and the PS5

- **WireGuard first, Tailscale as the fallback.** In-kernel WireGuard is the fast path; Tailscale is
  userspace Go, costs RAM, and buys NAT traversal with no port forward — what a hotel needs. ❓ both
  unmeasured: `modinfo wireguard`, then `iperf3` through the tunnel.
- **Hotel networks block UDP often enough to plan for it.** TCP/443 fallback is the known answer.
- **Plex has no ARM64 Linux client.** A Kodi addon against the server, direct-playing so decode
  lands on the VPU. Jellyfin is the same shape with a better Linux story.
- **PS5 Remote Play last.** `chiaki-ng` is the client and decode is ✅, so the risk is latency: the
  display path again, a DualSense on the same TDD antenna as the video, and a WAN round trip if it
  runs through the VPN.

## Build order

| #   | Step                                        | Unblocks                      |
| --- | ------------------------------------------- | ----------------------------- |
| 1   | Zero-copy KMS video path                    | Kodi, AirPlay video, Chiaki   |
| 2   | Kodi on GBM, GUI at 1080p                   | everything with a UI          |
| 3   | CEC: One Touch Play, Standby, TV remote in  | the remote experience         |
| 4   | YouTube addon, Premium login, pinned to VP9 | the most-used source          |
| 5   | Powered hub                                 | flash playback, port count    |
| 6   | WireGuard, then Plex or Jellyfin over it    | home library, hotel networks  |
| 7   | `iw phy` answer, then Wi-Fi onboarding      | plugging into an unknown room |
| 8   | Voice GATT decoder, then local STT          | the voice key                 |
| 9   | Chiaki                                      | the extra prize               |

## Done means

The stick plugs into an unfamiliar TV, joins that room's network from the remote alone, wakes the TV
and switches its input by itself, and plays from home, from YouTube, from a stick and from a phone —
with the TV's own remote working as well as its own.

## Not on the table

- **Google Cast reception** — closed protocol, certification-gated. The DIAL + Lounge subset is on
  the table and tracked above.
- **HD from the DRM services** — L3 only, and the box reports a reference-design model anyway.
- **8K to the screen** — the VOP tops out at 4096 px wide. 8K decode to a file is fine.
- **AV1 at 1080p60 or 4K** — no hardware, and the software rate is a synthetic best case.
