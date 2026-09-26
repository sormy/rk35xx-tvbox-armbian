# The Wi-Fi TX rate that latches at 6 Mbit/s

✅ **Root-caused in the driver and fixed**, deployed 2026-08-25 and live across two reboots
(`txba_stale_sec=10`). 🟡 Not re-tested against the reproducer since — inducing the latch needs 2.4
GHz plus CPU load on a daily driver.

TX parks at the lowest basic rate, upload collapses, download stays healthy, and it does not recover
on its own. The latch is **per-TID**: only BE/BK are pinned, VI/VO keep running HE-MCS 9–11 on the
same radio at the same instant.

## Root cause: a TX BA session the firmware drops without saying so

`skw_setup_txba()` runs on every TX frame and its only gate is `peer->txba.bitmap`, set when
`ADD_TX_BA` is _queued_ and cleared only on a send failure, an error status, or `DEL_TX_BA`. When
the firmware drops a session without sending `DEL_TX_BA` the bit stands, the function early-returns
forever, and that TID never renegotiates. No BA means no A-MPDU, so the link loses HE — and the
ladder drops legacy OFDM when the peer advertises HE, leaving 6.0 Mbit/s as the highest survivor.

Instrumented over 300 s: 54 `DEL_TX_BA`, 53 `ADD_TX_BA`, sessions renegotiated about every 5 s. Only
the last teardown goes unreported. TID 0's final event is `ADD_TX_BA` status 0 at t+168.6 s, the
latch lands at t+170–180 s, and nothing follows, while TIDs 1 and 4 keep cycling.

## The fix

`patches/seekwave-swt6621s/0002-skw-renegotiate-silently-dropped-tx-ba.patch`, applied to the pinned
driver by `fetch-seekwave-src.sh`. Suspicion is a session claimed longer than `txba_stale_sec`
(default **10 s**, against ~5 s measured); confirmation is a `GET_STA` showing `tx.rate` legacy
while `rx.rate` is not, which cannot happen on a working aggregated link. A peer with no HE reads
legacy both ways, so it never fires there. On by default.

Validated by toggling `txba_stale_sec` on a single latched association — no reload, no
re-association, same load:

| Toggled at | Recovered           |
| ---------- | ------------------- |
| +10 s      | 4.65 → 74.44 Mbit/s |
| +20 s      | 4.61 → 77.76 Mbit/s |
| +30 s      | 4.57 → 75.29 Mbit/s |

Each recovery coincides with a `stale TXBA` log line. Untreated controls held 18–21 consecutive
samples at 6.0 Mbit/s.

🟡 **`0001-skw-txba-rearm-quirk.patch` is superseded and not shipped.** It re-arms on a blind timer
rather than on evidence, and against an AP that holds a BA session for minutes it would renegotiate
a healthy link every interval. It does cover HT-only and legacy peers, where 0002 cannot fire for
want of an HE downlink; whether the fault occurs there is untested.

## DSCP VI remains a zero-driver mitigation

A flow marked VI (`0xa0`) never sees the latch — 58.4 Mbit/s on VI against 3.53 on BE, same link,
same second — and it is the correct marking for video anyway. Useful on an unpatched driver.

**Re-associating is the last resort**: it clears the latch (5.94 → 99.8 Mbit/s), but drops the link
for 0.2–0.3 s on 5 GHz and 3.1–3.5 s on 2.4 GHz. Nothing here ships to do it automatically.

## Reproduce

2.4 GHz, `stress-ng --cpu 4`, Wi-Fi **idle** during the load, measure after the load stops. 4/5 on a
stock image with the band pinned.

All three ingredients matter: idle Wi-Fi gives the firmware no TX attempts, CPU load starves the
`SCHED_OTHER` TX workqueue, and 5 GHz rarely latches. CPU load _with_ traffic running does not
reproduce it — the traffic supplies the attempts. Nor does MMC/SDIO IO load on its own.

🟡 **A possible fourth ingredient: the SD card in use.** Every reproduction so far ran from SD with
the card active, and SDIO Wi-Fi shares the `dwmmc` block with it. Untested as a variable — repeat
from eMMC with the slot empty to rule it in or out.

## The measurement that settles it

One association, same second, only the DSCP marking differing:

| AC  | TID | throughput    | firmware reports after a burst |
| --- | --- | ------------- | ------------------------------ |
| BE  | 0   | **3.53** Mbps | `legacy_rate: 60, legacy`      |
| BK  | 1   | **3.40** Mbps | —                              |
| VI  | 4   | **58.4** Mbps | `mcs: 11, ieee80211ax`         |
| VO  | 6   | **53.1** Mbps | `mcs: 9, ieee80211ax`          |

Rate state is per-TID, which rules out RF, TX power, calibration and a degenerate per-STA ladder. At
the pinned rate `psr: 92–99` and `tx_failed: 0` — the link is clean, the ladder simply never probes
upward. 150 s of continuous BE load produced not one up-probe.

## What the firmware does once BA is gone

Superseded as _the_ root cause by the driver finding above, and kept because it explains why the
rate never climbs back on its own once aggregation is lost.

A probe scores as lost whenever the probed rate did not accumulate `cfg[0x25]` attempts, which is
exactly what an idle link cannot do. The backoff at `ctx[0x1a9]` is a signed char incremented by
`1<<exp` with no clamp on the sum, so it wraps negative; a negative value still suppresses, and the
decrement walks it further from zero.

## Diagnostics and firmware access

- `/proc/skwifid/chip1.sdio/wlan0` — per-peer TX mode, rate, `psr`, `tx_failed`, per-AC queue depth.
  `iw dev wlan0 station dump` is empty on this driver, so this is the only per-peer view. ⚠️ **A
  passive read of its TX rate is stale.** `peer->tx.rate` is written in exactly one place, the
  get_station handler at `skw_cfg80211.c:2334`, so `cat`ting this node shows whatever was last left
  there. Measured 2026-08-26: it read `legacy_rate: 60` continuously while the link moved 72 MB and
  benchmarked 78.3 Mbit/s. Trigger a refresh with `iw dev wlan0 link`, which issues get_station, or
  judge by throughput. This does not affect `0002`, which polls `GET_STA` itself and reads the
  response — the reason v1, which gated passively on this field, never fired unattended.
- Private WEXT ioctl `0x8BE1` on `wlan0`: `addrval=<addr>,<val>` maps to a firmware
  `*(u32*)addr = val` — arbitrary write, enough to patch code in a running chip. `rcminrate` forces
  a ladder rebuild, which does **not** clear the latch.
- Measure with `iperf3 --bind-dev wlan0`. `-B <wifi-ip>` does not force the interface on a box that
  also has ethernet; check `/sys/class/net/*/statistics/tx_bytes`.

The image is **not** encrypted and **not** checksum-enforced — a deliberately corrupted byte loaded
and ran.

|              |                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------ |
| Architecture | **ARM Cortex-M, Thumb** — valid vector table at 0: SP `0x00107fd8`, reset `0x00104725` (Thumb bit set) |
| Load base    | `0x00100000` to `0x00157F80`                                                                           |
| Stack        | **RivieraWaves / CEVA** — `rwip.c`, `rwble.c`, `sch_arb.c`, `machw_*`, `ke_event_ext.c`                |
| Build        | `20260307-01:02:24`                                                                                    |
| Rate control | `rate_control.c` in the assert filename table, file offset `0x406e2`                                   |
| Images       | IRAM 360 KB code, DRAM 193 KB data; three unique images across the board-suffixed copies               |

There is an AT interface (`at+wifimpset=1` enters manufacturing mode), but the command table is
assembled rather than stored whole — only `+WIFI`, `+ERR`, `+LOG`, `+PLD`, `+TAP`,
`WIFIEN`/`WIFIDIS`/`WIFIREADY` appear in strings.

## Firmware patches tried, none fixed it

This was the earlier line of attack, before the TX BA gate was found. None of it ships; recorded so
the ground is not covered twice.

Alternating blocks of 4 reps, one install per block, band pinned, scored on throughput:

| variant                                                        | latched               |
| -------------------------------------------------------------- | --------------------- |
| stock                                                          | **5 / 8**             |
| bypass both probe-suppression paths (`0x2c800` = `0xe0144288`) | **2 / 8**             |
| clear the backoff counter (`0x2c890` = `0x29ff2000`)           | 3 / 4                 |
| bound the backoff (`0x2c890` = `0x29ffbf00`)                   | 2 / 2, never recovers |

Remaining candidate: a deadlock in candidate selection — only rates that already have `cfg[0x25]`
attempts are scored, so once the ladder is at the bottom no higher rate can accumulate any.

Patches do reach the chip (an image differing by 5 bytes fails to boot), but **not every byte is
patchable**: `0x2c890` and `0x57ea2` tolerate edits, `0x14f20` does not. Verify the chip still boots
after any new patch site.

## If you hit it

1. `iw dev wlan0 link` — a large tx-vs-rx asymmetry at a strong signal is the signature.
2. Measure sustained upload with `iperf3`/`nc`, **never** over `ssh`.
3. `sudo wpa_cli -i wlan0 reassociate`, then re-measure. That has cleared it every time.

## Ruled out

| Theory                         | Killed by                                                                |
| ------------------------------ | ------------------------------------------------------------------------ |
| TCP window / congestion        | 4 parallel streams reached 9.0 Mbit/s; UDP offered 50 Mb pushed 5.7      |
| RF, TX power, calibration      | per-TID: VI/VO run MCS 9–11 on the same radio at the same instant        |
| Driver does no rate adaptation | same box sustains 380 Mbit/s up at HE-MCS 11 when not latched            |
| Stuck driver state             | survives nothing — many reboots since, and reassociation alone clears it |
| Host TX scheduling asymmetry   | the per-TID result: not a host artefact (see below)                      |
| Firmware image is checksummed  | a corrupted byte loaded and ran                                          |

The TX-scheduling lead was real as an observation and wrong as a cause. RX runs `SCHED_FIFO`
kthreads (`skw_rx.c:1726`, `skw_sdio_main.c:1018`) while TX is an
`alloc_workqueue(WQ_UNBOUND|WQ_CPU_INTENSIVE|WQ_HIGHPRI)` (`skw_tx.c:1424`) — `WQ_HIGHPRI` only sets
the pool's nice, so the workers stay SCHED_OTHER. That matches the failure's shape, but the per-TID
measurement shows the collapse is not a host scheduling artefact. The driver does no rate selection
at all: `tx_rate` comes from `SKW_CMD_GET_STA` and `set_bitrate_mask` is unimplemented, so
`iw set bitrates` cannot help either.

## History

2026-08-09, box capturing MJPEG from two USB cameras — upload collapsed, download healthy, signal
−33 dBm, `rx 600.4 MBit/s HE-MCS 11` against `tx 6.0 MBit/s`:

| Path                          | Up             | Down       |
| ----------------------------- | -------------- | ---------- |
| box → peer on Wi-Fi           | 5.8–6.1 Mbit/s | 197 Mbit/s |
| box → peer on Ethernet        | 5.6 Mbit/s     | 268 Mbit/s |
| box → peer, 4 parallel TCP    | 9.0 Mbit/s     | —          |
| box → peer, UDP offered 50 Mb | 5.7 Mbit/s     | —          |

2026-08-11, same box and AP after a reboot: **600.4 MBit/s** HE-MCS 11, 380 up / 414 down to a wired
peer, −34 dBm.

2026-08-16, induced and cleared on one unchanged link (Wi-Fi peer, so absolute numbers are
path-limited — the ratios are the evidence):

| Step                                   | tx PHY    | rx PHY | upload   |
| -------------------------------------- | --------- | ------ | -------- |
| found latched on arrival, box idle     | 6.0       | 540.3  | 5.98     |
| `wpa_cli reassociate`                  | 129.0     | 129.0  | 74.3     |
| during `stress-ng --cpu 4`             | —         | —      | **3.56** |
| immediately after that load stopped    | —         | —      | 3.82     |
| after a further 60 s idle              | **6.0**   | 143.3  | 3.72     |
| `wpa_cli reassociate`                  | **360.3** | 540.3  | **199**  |
| `stress-ng --cpu 4` at `chrt -i 0`     | 600.4     | —      | 193      |
| `stress-ng --cpu 4` **repeat, normal** | 600.4     | —      | **214**  |

Sixty seconds after the load stopped the PHY was still parked at 6.0 — a latch, not contention. The
last row is why CPU load alone is not the trigger: the same normal-priority four-core load, repeated
in the same session, did not latch.

Tools, installer and full write-up: `rk35xx-tvbox-armbian/research/seekwave-tx-latch-bug/`.
