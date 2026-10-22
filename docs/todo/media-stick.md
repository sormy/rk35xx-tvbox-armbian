# A universal media stick

One stick, HDMI into whatever screen is to hand, everything else over Wi-Fi. Measured on the H96 Max
3518D; `docs/h96max-3518d/board.md` is what that **board** still needs, this is what the **stack**
needs. None of it is built yet.

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

- **The display path is the ceiling.** 4K HEVC decodes at 110 fps through
  `-hwaccel rkmpp -hwaccel_output_format drm_prime` and reaches the screen at 27, because every
  frame is copied into `/dev/fb0`. The fix: import the dmabuf as a DRM framebuffer and page-flip it
  onto `Cluster0-win0`, DRM plane 266, vp0's only overlay taking NV12 and NV15. Kodi, AirPlay
  mirroring and Remote Play all wait on it.
- **The decoder speaks MPP, not V4L2.** `/dev/mpp_service`, no `/dev/video*`; a player reaches it
  through an ffmpeg with `rkmpp`, or GStreamer's rockchip elements. The packaged
  `libgstrockchipmpp.so` is 1.14.4 against a 1.26.2 core and fails every pipeline. Debian's Kodi
  links Debian's ffmpeg, which has no `rkmpp`: the one unproven link.
- **V4L2 is the alternative, not the plan.** `CONFIG_VIDEO_ROCKCHIP_VDEC=m` in the fragment selects
  the request API; RK3528's VDPU382 then needs a port from its mainline neighbours, H.264 first. It
  buys stock GStreamer, Kodi and Chromium, not speed, and takes the decoder from MPP.
- **2 GB of RAM, GLES 2.0, a 4096 px limit.** GUI at 1080p, video on the plane; no Chromium UI.
- **Widevine is L3:** Netflix, Prime and Disney+ cap at SD/720p. Local files, Kodi, Jellyfin, Plex
  and YouTube are unaffected.
- **One 5 V rail** feeds the SoC and both USB ports: a powered hub answers storage, ports and
  hot-plug, and keeps USB-C, the only OTG port, free.
- **Sleep on the remote is parked:** `research/seekwave-bt-wake/`. Idle is under 0.5 W.
- **Cast, AirPlay, DLNA and a LAN Plex need mDNS on the same segment;** on a hotel network with
  client isolation the VPN is the only path home.
- **The handset falls back to IR** when its BLE link drops, and a TV in the room acts on power and
  OK: a CEC standby and an IR power press can undo each other.
- **YouTube pinned to VP9:** AV1 has no hardware; software AV1 is 40.6 fps on four cores.
- **AirPlay mirroring** through `uxplay` inherits the GStreamer chain; software H.264 is 14 fps.
- **Voice** rides the Android TV GATT service (`ab5e0001…`): a BlueZ client, then `vosk` or
  `whisper.cpp tiny` on four A53s. Never probe the `0xae00`/`0xae40` vendor pairs: they look like an
  OTA control point.
- **Captive portals** must see the box's MAC: an on-screen browser, or a phone's address given to
  `wlan0` after registering it.
- **WireGuard first**, Tailscale as the fallback for NAT traversal; TCP/443 where UDP is blocked.

## Build order

| #   | Step                                        | Unblocks                      |
| --- | ------------------------------------------- | ----------------------------- |
| 1   | Zero-copy KMS video path                    | Kodi, AirPlay video, Chiaki   |
| 2   | Kodi on GBM, GUI at 1080p                   | everything with a UI          |
| 3   | The Kodi image                              | delivery                      |
| 4   | CEC: One Touch Play, Standby, TV remote in  | the remote experience         |
| 5   | YouTube addon, Premium login, pinned to VP9 | the most-used source          |
| 6   | Powered hub                                 | flash playback, port count    |
| 7   | WireGuard, then Plex or Jellyfin over it    | home library, hotel networks  |
| 8   | `iw phy` answer, then Wi-Fi onboarding      | plugging into an unknown room |
| 9   | Voice GATT decoder, then local STT          | the voice key                 |
| 10  | Chiaki                                      | the extra prize               |

**The Kodi image** is `tvbian-<date>-<board>-trixie-kodi.img.xz`: the same image step plus a Kodi
package list, Kodi started at boot, released alongside the plain images. Only once steps 1 and 2
work. It can be sealed once sealed images exist.

## Done means

The stick plugs into an unfamiliar TV, joins that room's network from the remote alone, wakes the TV
and switches its input by itself, and plays from home, from YouTube, from a stick and from a phone —
with the TV's own remote working as well as its own.

## Not on the table

- **Google Cast reception** — closed protocol, certification-gated; DIAL + Lounge is tracked above.
- **HD from the DRM services** — L3 only.
- **8K to the screen** — the VOP tops out at 4096 px wide.
- **AV1 at 1080p60 or 4K** — no hardware.
