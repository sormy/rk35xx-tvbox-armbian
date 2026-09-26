# Seekwave SWT6621S firmware — TX rate latch

Reverse engineering of the Wi-Fi firmware on the H96 Max (RK3518) box, to explain why the TX rate
latches at 6.0 Mbit/s and never recovers without re-association.

Symptom, measurements and workaround history: `../../docs/h96max-h313/wifi-tx-latch.md`.

## Result — a firmware bug the driver fails to notice

_(Supersedes an earlier "it is a driver bug, not firmware" claim here, and the v1 fix it described.
Corrected 2026-08-23 — see `wifi-latch.md`.)_

**The firmware drops a TX Block Ack session and does not send `DEL_TX_BA`.** The driver's flaw is
trusting it: `skw_setup_txba()` marks a session established when `ADD_TX_BA` is merely _queued_, and
clears that mark only on a send failure, an error status, or an explicit teardown. With no teardown
delivered, the bit stands, the function returns early on every subsequent frame, and that TID never
renegotiates for the life of the association.

Measured with instrumented BA logging over a 300 s reproduction: **54 `DEL_TX_BA` and 53
`ADD_TX_BA`** — sessions churn every ~5 s and the firmware reports those teardowns reliably. What
fails is the _last_ one. TID 0's final event is an `ADD_TX_BA` status 0 at t+168.6 s, the latch
lands t+170-180 s, and no `DEL_TX_BA` ever follows, while TIDs 1 and 4 keep cycling normally.

(An earlier version here claimed `tidmap` read `0x1` at all 24 samples so "none was ever received".
That was an artefact: sampling every 10-15 s cannot see a 5 s churn, so each `0x1` was a _fresh_
session, not a stale one.)

HE data frames are carried in A-MPDU, which requires a BA agreement — so the TID loses HE entirely.
The rate ladder strips legacy OFDM whenever the peer advertises HE, leaving `1, 2, 5, 6` legacy plus
HE-MCS 0-11. With HE unusable the highest surviving rung is **6.0 Mbit/s**: the observed floor.

Shipped as a quirk, default off: `patches/0001-skw-txba-rearm-quirk.patch` (18 lines, two files).
Enable with `swt6621s_wifi.txba_rearm_sec=30`. Matched-build interleaved A/B: control latched 2/2
and never recovered (→4.6 Mbit/s); patched dipped but self-recovered 7 and 8 times _while still
loaded_, finishing at 62-70 Mbit/s on HE-MCS 9.

Two earlier claims here were wrong and are worth recording. The v1 fix gated on the observed TX
rate; `peer->tx.rate` is written only by the get_station handler, so it never fired unattended, and
its apparent validation came from the test harness polling that very field. And the "~60% of
attempts" stock latch rate is about right after all — with the three necessary conditions held (2.4
GHz, continuous load, sparse traffic) stock latches roughly half to two-thirds of 300 s arms
(measured 2026-08-23: 4/4, then 3/5, then 2/3 across sessions). It is not deterministic, which is
why small A/Bs here are underpowered.

Everything below documents the firmware investigation that preceded this. It is retained because it
records how ten plausible firmware theories were tested and refuted — all of them failed for the
same reason: **the bug was never in the firmware.**

> **RETRACTED 2026-08-20.** The panic-fallback attribution below is **wrong**, refuted by direct
> measurement. A peek of `ctx[0x1bd]` during a throughput-confirmed latch (78.3 -> 5.17 Mbit/s,
> `psr: 100` so the readout was live) reads **0 — the flag is clear while the rate is pinned**.
>
> The A/B numbers that appeared to support it (stock 9/16, flag variants 20-33%) were stimulus
> drift, not effect. The stimulus varies enough between windows to produce that spread on its own,
> which is why no variant ever eliminated the latch.
>
> What survives: the reproduction, the band finding, and the code tracing of the flag (one write
> site, one consumer). What does not: that the flag causes the latch.
>
> Kept below for the mechanism description and to record how the wrong conclusion was reached.

**Superseded: a "panic" fallback misfires. It is not a rate-control defect.**

`FUN_0012c338` arms `ctx[0x1bd]` when no rate scored above zero **and** fewer than four rates
cleared the minimum-attempts gate. Its only consumer, the chain builder, then forces the TX chain's
fallback entry from 24 Mbit/s down to 6 Mbit/s:

    0012c418  cmp r0,#3 / itt ls / movls r0,#1 / strbls.w r0,[r6,#0x1bd]
    0012c9d8  else if (rate_ratio < 0x23 || ctx[0x1bd] != 0) slot = 0x30   // 6 Mbit/s

Host CPU starvation stalls TX-completion processing, so the per-rate statistics go missing while the
radio stays healthy. The firmware cannot distinguish _"I measured failures"_ from _"I have no
measurements"_, reads the empty table as a dead link, and pushes traffic onto 6 Mbit/s. Statistics
then accumulate at 6 Mbit/s and the selector legitimately converges there — which is why the pinned
rate reports `psr 92-99, tx_failed 0`. The ladder is faithfully tracking a situation the flag
manufactured.

**Fix.** Every arm below was interleaved against a stock control in the same window:

| build                | change                                       | latched |
| -------------------- | -------------------------------------------- | ------- |
| stock                | —                                            | 6/9     |
| **flag never armed** | `movls r0,#1` -> `#0`                        | **0/3** |
| evidence gate        | `cmp r0,#3 / itt ls` -> `cmp r0,#0 / itt ne` | 1/5     |
| wrong direction      | `cmp r0,#3` -> `cmp r0,#0`                   | 2/2     |

The evidence gate — arm only when some rate produced data and still scored zero — reduces the rate
but does **not** eliminate it. That is itself a finding: under starvation the firmware sometimes
does record attempts with zero successes, because lost completions are counted as failures. In that
state the statistics table is genuinely indistinguishable from a failing link, so **no gate reading
only the statistics can separate host starvation from RF failure**.

Separating them needs RF-side evidence, which the firmware already computes: `ctx[0x1a6]`, the
averaged per-completion RF metric maintained in `FUN_0012d710`. A correct gate would suppress the
fallback while that metric is healthy. Not yet implemented.

Currently the only candidate with no latches is removing the flag outright. That is defensible but
blunt: the flag only selects the _retry-chain fallback slot_ (24 -> 6 Mbit/s), so removing it does
not disable rate adaptation — a genuinely bad link still descends the ladder normally, it just stops
forcing retries to the basic rate. Reps are still accumulating.

This supersedes the earlier "no firmware patch fixes this" conclusion, and explains why: every one
of those candidates repaired the _climbing_ machinery — probe scheduling, backoff, the attempt gate,
ladder composition — while the rate was being overridden downstream of the ladder entirely. The
`force HE` negative fits too: the ladder did hold good rates, and the chain builder overrode them.

Two things earlier work got wrong, both load-bearing:

- **The band is the reproduction variable, not CPU load.** The same stimulus does nothing on 5 GHz
  at load 14 with saturated TX, and latches on 2.4 GHz in under 60 s. Not signal strength — it
  reproduced at −23 dBm on 2.4 GHz where −32 dBm on 5 GHz would not budge. Every "nothing reproduces
  any more" episode was this, not the DTB and not a phantom fix.
- **Earlier refutations were scored against a stimulus whose own control ran 0/6.** Re-tested
  against a control that latches on demand, `clamp nop` is still refuted — but the verdicts are now
  worth something.

Not tested: the preserved fallback path for a link that really is failing. This hardware exposes no
TX-power control and no bitrate masks, so a genuinely bad link cannot be created on demand.

## How the algorithm is meant to work, and where it breaks

Minstrel-style: descend by measurement, ascend by sampling.

| element                   | role                                                            |
| ------------------------- | --------------------------------------------------------------- |
| ladder `ctx+0x18` (<=28)  | admitted rates, ascending                                       |
| `ctx[0xaa]` / `ctx[0xa4]` | current index / top index                                       |
| stats `ctx+0xbc+8i`       | `+0x194` attempts, `+0x19a` EWMA success %                      |
| `FUN_0012c338`            | among rates with `attempts >= cfg[0x25]`, maximise `pct x mbps` |

- **state 0** bootstrap: `ctx[0xaa] = ctx[0xa4] - 1`, no stats consulted
- **state 1** exploit: adopt best; if best == current and not at top, go sample
- **state 2** sample: transmit at `current + cfg[0x29]` for 3 intervals, re-score, promote if better
  else back off `1<<exp`
- **state 3** spacing between probe intervals

**Two defects.**

1. _Stats are wiped every evaluation_ — `FUN_0013dfae(ctx+0xbc, 0xe0)` zeroes all 28x8 blocks at the
   end of each selector run. Minstrel decays stats so previously-sampled rates stay comparable;
   wiping means only the rate transmitted in the last interval is ever eligible, so
   `best == current` is true almost by construction and the exploit path cannot climb on its own.
2. _The probe step appears to be 0_ — ascent happens only in state 2, at `current + cfg[0x29]`. With
   0 the probe transmits at the rate already in use, so no higher rate ever gains attempts.

Defect 1 alone is survivable; defect 2 is fatal, and together ascent is impossible. `cfg[0x29]` is
also reused immediately after as the descending retry-chain length (`if (uVar4 < cfg[0x29])`), so 0
degenerates both — the signature of a config byte that was never initialised (the struct behind
`DAT_001081e0` is ROM-owned BSS).

This explains every refuted patch: they altered ladder contents, suppression, backoff or the
capability map, none of which matter if the sample never transmits higher.

**The proper fix is initialisation, not logic.** Give `cfg[0x29]` its intended non-zero default
(~2-3) along with its siblings. The state machine, scoring metric and backoff are all correct as
written. Without firmware source the equivalent correct fix is a driver-side write of those defaults
at association via the vendor's own MIB 0x51 — supplying the missing initialisation through the
documented interface, unlike DSCP marking or a reassociation watchdog which only mask the symptom.

**Status: inferred, not measured.** `rdaddr` is dead on this build so `cfg[0x29]` cannot be read
back. One run with it set to 3 did not latch; the follow-up A/B was inconclusive because stock
stopped latching (0/3). Confirming it needs either a hot window or a readback patch that stores the
value into a driver-reported field.

## Original reading (superseded in part)

**The rate ladder collapses to a single 6 Mbit/s entry, and nothing but a fresh association can
rebuild it.** `rc_init` refreshes a link's capability map only on the _first_ initialisation; every
later rebuild re-derives the ladder from a map it never refreshes. With a stale map the HT/VHT/HE
entries are all rejected, the builder deletes every OFDM rate except 6 Mbit/s, and the ladder's max
index becomes 0 — so even the module's own recovery path lands on 6 Mbit/s.

Two-byte fix (`recap`) at `0x0012d688`, **not yet confirmed** — see below.

Details: [suppression sites](#the-suppression-sites) ·
[root cause](#root-cause-the-capability-map-is-refreshed-only-once) · [reproduction](#reproduction)
· [what to ship](#what-to-actually-ship)

### The measurement that opened it up: the latch is per-TID

BE/BK are pinned to legacy 6 Mbit/s while VI/VO run HE-MCS 9–11 on the same association, in the same
second. One association, only the DSCP marking differing:

| AC  | TID | throughput    | reported after a burst of that class |
| --- | --- | ------------- | ------------------------------------ |
| BE  | 0   | **3.53** Mbps | `legacy_rate: 60, legacy`            |
| BK  | 1   | **3.40** Mbps | —                                    |
| VI  | 4   | **58.4** Mbps | `mcs: 11, ieee80211ax`               |
| VO  | 6   | **53.1** Mbps | `mcs: 9, ieee80211ax`                |

## What that rules out

| Hypothesis                                 | Killed by                                                                                 |
| ------------------------------------------ | ----------------------------------------------------------------------------------------- |
| RF, TX power, calibration                  | VI at MCS 11 on the same link, same instant                                               |
| Rate control behaving correctly            | `psr: 92–99`, `tx_failed: 0` at the pinned rate                                           |
| Slow recovery                              | 150 s continuous BE load, never one up-probe                                              |
| Accumulated probe backoff                  | forced failures then release did not induce it, 4/4                                       |
| A misconfigured tunable                    | MIB 0x51 class counts + retry limits + `rcsperate` swept, no effect                       |
| One ladder **shared** by the whole station | a shared ladder cannot let VI reach MCS 11 while BE sits at 6, so the context is per-link |

Re-association clears it: 4.54 → **257–266** Mbps. A firmware ladder rebuild (MIB 0x50) does not,
even after 16 s of load, with the link never dropping.

## The suppression sites

`FUN_0012c740` state 1, from the loaded image:

```
0012c7fc  ldrb.w r1,[r5,#0xa4]   ; ladder max index
0012c800  cmp    r0,r1
0012c802  beq    0x12c79e        ; (A) best == max -> return, never probes
0012c804  ldrb.w r0,[r5,#0x1a9]  ; probe backoff
0012c808  cbz    r0,0x12c82e     ;  0 -> enter probe state
0012c80a  subs   r0,#1
0012c80c  strb.w r0,[r5,#0x1a9]
0012c810  b      0x12c79e        ; (B) backoff pending -> return
```

**Neither (A) nor (B) is the pin** — patching both changed nothing (see below). Reading the builder
settles it differently.

### Re-association recovers on the same channel, so it is the association itself

Band pinned to one 2.4 GHz channel, BSSID identical before and after:

```
LATCHED   bssid=<redacted-bssid> freq=2462 iw=6.0     4.89 Mbps
AFTER     bssid=<redacted-bssid> freq=2462 iw=143.3   102  Mbps
```

Not a band steer. 21× from the association alone.

### What association does, and why a rebuild is not enough

`rc_init` (`FUN_0012d284`) resets `ctx[0x1b4]` to 0 and calls the tick, whose case 0 jumps the rate
index straight to `ctx[0xa4] - 1` **without consulting any statistics**. That is the whole recovery
— and `rcminrate` does reach it: `cmd 0x50` sets `cfg[0x24] = 1`, and the periodic tick calls
`FUN_0012d284` on that flag. So the rebuild _runs_ and still lands on 6 Mbit/s.

The only way that happens is `ctx[0xa4] == 0` — **a one-entry ladder**:

```c
if (bVar1 != 0) ctx[0xa4] = bVar3 - 1;                // max = admitted - 1
case 0: bVar4 = max; if (max != 0) bVar4 = max - 1;   // 1 entry -> index 0 -> 6 Mbit/s
```

An earlier claim that a rebuilt ladder "contains HE entries" is withdrawn — it rested on forcing
`rcminrate=0x37`, which changes which entries are admitted, so it proved nothing.

Stale statistics are also not involved: the selector wipes all 28 per-rate stats at the end of every
run (`FUN_0013dfae(ctx + 0xbc, 0xe0)`), so each interval only rates actually transmitted during it
can be candidates.

### How the ladder collapses to one entry

```c
if (cVar2 == '\x01') {                        // OFDM class
    cVar2 = rate_table[i].code;
    if ((*(byte *)(iVar4 + 0xc) & 7) != 0) {  // peer is HT/VHT/HE capable
        if (cVar2 != '0') goto drop;          // '0' == 0x30 == 6 Mbit/s
```

Every OFDM rate except 6 Mbit/s is deleted whenever the peer advertises HT/VHT/HE. If the HT/VHT/HE
admission then fails, exactly one entry survives and the ladder is permanently pinned to its own
top. Re-association fixes it because the peer capability record is repopulated first.

Patching that deletion (`ofdm` variant, `0x0012d38c` `beq` → `b`) moved the pinned rate from **6.0
to 9.0 Mbit/s** — twice — which proves the ladder composition determines what it pins to. It did not
change how often it latches (stock 2/8, ofdm 2/8), so it is evidence, not a fix.

### Root cause: the capability map is refreshed only once

`rc_init` calls the ROM routine that populates the link's capability map **only on the first
initialisation**:

```
0012d67c  cbz  r0,0x12d68c     ; state == 0 -> ROM populate path
0012d684  strb r0,[lr,#0x1b4]  ; else: state = 0
0012d68a  b    0x12d6b0        ; ...and branch past the ROM call
0012d68c  ldrb cfg[0x2d] ; bl 0xc8c48    <- populates capabilities
```

So every later rebuild resets the state but re-derives the ladder from a map it never refreshes. If
that map is stale, HE/VHT/HT admission fails, the OFDM deletion above leaves only 6 Mbit/s,
`ctx[0xa4]` becomes 0, and case 0's "recovery" jumps to index 0 — 6 Mbit/s. Every subsequent rebuild
reproduces it. Only re-association escapes, because a fresh context has state 0 so the ROM populate
runs.

**Fix `recap`** — `0x0012d688`, retarget that branch to `0x12d68c` (`0xe0114677` → `0xe7ff4677`), so
a rebuild resets the state **and** refreshes capabilities. Two bytes.

Measured, same stimulus, same window:

|                                        | stock                              | `recap`                   |
| -------------------------------------- | ---------------------------------- | ------------------------- |
| latched                                | attempt 2 of 6 — 4.89 Mbps, iw 6.0 | **0 / 6** — 96.8–104 Mbps |
| MIB 0x50 rebuild on the latch          | still 6.0 / 5.42 Mbps              | —                         |
| association events during that rebuild | **0** — link never dropped         | —                         |

The zero association events matter independently: the vendor rebuild **is** the non-disruptive slice
of re-association, and it already runs without dropping the link. It simply does not help on stock
because it skips the capability refresh.

**Not yet conclusive.** `recap` has 0 latches in 14 reps, but a follow-up alternating A/B returned
**stock 0/8, recap 0/8** — the stimulus had gone quiet, so it discriminates nothing. The latch
reproduces in _bursts_: several windows today gave 3-4 hits in 8 reps, then nothing for half an
hour. Any future comparison must confirm the stock arm is latching in the same window, or it is
worthless — that mistake has now invalidated two separate results.

### Why the stimulus works — low offered load

A separate defect sits in the same module and shaped much of this investigation: the backoff
accumulator at 34146-34155 adds up to +64 per lost probe to a **signed char** with no clamp, so it
wraps negative, and the suppression test is `!= 0`. Patching it three ways changed nothing, so it is
a real bug but not this one. What it does explain is why the stimulus works — the candidate selector
`FUN_0012c338` admits a rate only once it has accumulated `cfg[0x25]` attempts:

```c
if ((uint)cfg_min_attempts <= *(uint *)(iVar4 + 0x194))   // attempts >= min
    score = success_pct * rate_table[ladder[i]].mbps;      // only then can it win
```

On an idle or CPU-starved link the probe rate never reaches that count, so every probe is scored as
lost. That is why a quiet window plus CPU load reproduces it, and why load _with_ traffic does not —
the traffic supplies the attempts. `tools/idle-repro.sh` tests it by holding the link idle or
trickle-loaded for 60–360 s before applying load.

Note `FUN_0012c338` reads its context as `*(int *)(param_1 * 4 + 0x202233b4)` — indexed per link,
which is consistent with the per-TID split measured above.

## Fix candidates

**The fix — `clamp`, aligned word at `0x0012c890`** (`tools/fwpatch.py <img> clamp nop <out>`):

```
0012c88c  lsl.w  r0,r2,r0   ; r0 = 1<<exp, exp saturates at 6, so <= 64
0012c890  add    r0,r1      ; += backoff   <-- unclamped, stored into a signed char
0012c89a  strb.w r0,[r5,#0x1a9]
```

| variant | word         | effect                           |
| ------- | ------------ | -------------------------------- |
| `orig`  | `0x29ff4408` | `add r0,r1`                      |
| `nop`   | `0x29ffbf00` | `nop` — backoff becomes `1<<exp` |

Backoff stays exponential and capped at 64 intervals, never accumulates, never wraps negative.
Suppression is kept; unboundedness is not. One instruction.

**No patch tested fixes it.** Alternating blocks of 4 reps, one firmware install per block, band
pinned, scored on throughput (`<40 Mbps` = latched; the `iw` column is sampled before traffic and
goes stale):

| variant      | word         | latched   | note                                           |
| ------------ | ------------ | --------- | ---------------------------------------------- |
| stock        | —            | **5 / 8** | baseline                                       |
| `bypass AB`  | `0xe0144288` | **2 / 8** | halves it; both failures on rep 4 of a block   |
| `clamp zero` | `0x29ff2000` | 3 / 4     | no effect                                      |
| `clamp nop`  | `0x29ffbf00` | 2 / 2     | no effect, and never recovers in 150 s of load |

An earlier comparison read 3/3 stock against 0/4 patched. **Withdrawn** — its stock arm ran in a
window where the stimulus was not reproducing at all (0/6 in a control immediately after).

So neither suppression path is the pin. The remaining candidate is the candidate-selector deadlock:
`FUN_0012c338` only scores rates that already have `cfg[0x25]` attempts, so once the ladder sits at
the bottom no higher rate can ever accumulate attempts, and nothing can ever score better. Bypassing
the probe gate does not help if the probe rate is never actually transmitted.

No regression on a healthy link for any variant: 97–277 Mbps under immediate load.

Apply with `tools/fwpatch.py <img> <site> <variant> <out>` then `tools/fw-install.sh <out>`;
`tools/fw-install.sh restore` puts the pristine image back.

## What to actually ship

**Mark the traffic DSCP VI (`0xa0`).** The latch is per-TID and spares VI/VO, so the marked flow
never sees it — 58.4 Mbps on VI against 3.53 on BE, same link, same second. No service, no firmware
change, no interruption. This is the fix for a link that has to stay up.

**Superseded by the driver fix.** Earlier mitigations lived here — a watchdog that detected a legacy
TX rate at strong signal and re-associated (it worked, 5.94 -> 99.8 Mbps, but re-association blacks
the link out for 0.2-3.5 s, which is worse than degraded throughput for anything real-time) and a
firmware image patch for a mechanism later refuted. Both are removed; `patches/0002` recovers in
10-30 s with no outage and ships by default. See the import commit for the old files.

### The patch really is running, and not every byte is patchable

Two images differing by 5 bytes behave differently on the chip, which settles it:

| image                                                        | result                                                    |
| ------------------------------------------------------------ | --------------------------------------------------------- |
| clamp (2 bytes @ `0x2c890`)                                  | boots, runs, reports its version                          |
| clamp + version string `trunk`→`TRUNK` (5 bytes @ `0x14f20`) | **fails to boot, twice** — `skw_boot_loader fail ret=-62` |
| clamp again                                                  | boots, runs                                               |

So file edits reach the chip. It also **corrects the earlier claim that the CRC is simply not
enforced** — `0x2c890` and `0x57ea2` tolerate edits, `0x14f20` does not. Validate any new patch site
by testing that the chip still boots.

**Blunt variants at `0x0012c800`**, only for isolating which path pins the rate — they disable
suppression outright, so a genuinely bad link would probe forever:

| variant | word         | effect                      |
| ------- | ------------ | --------------------------- |
| `orig`  | `0xd0cc4288` | `cmp r0,r1 ; beq 0x12c79e`  |
| `A`     | `0xbf004288` | `nop` — bypass (A) only     |
| `AB`    | `0xe0144288` | `b 0x12c82e` — always probe |

**Live patching is not a usable test method.** Every `addrval` write costs exactly one
re-association — including a no-op write of the identical value, and a write to unused DRAM. An
apparent 5.24 → 271 Mbps "fix" on a live latch was that reset, and is retracted. Patches must go
into the image (`tools/fwpatch.py`) followed by a module reload.

## Host access to firmware internals

Private WEXT ioctl `0x8BE1` on `wlan0` (`SIOCIWFIRSTPRIV+1`), name/value subcommands:

| subcommand             | firmware | effect                                                        |
| ---------------------- | -------- | ------------------------------------------------------------- |
| `addrval=<addr>,<val>` | MIB 0x96 | `*(u32*)addr = val` — **arbitrary write**                     |
| `rdaddr=<addr>`        | —        | driver path exists, firmware acks 0 bytes; dead on this build |
| `rcminrate=<code>`     | MIB 0x50 | `cfg[0x2c]=code`, `cfg[0x24]=1` → ladder rebuild              |
| `rcratechg=v1..v5`     | MIB 0x51 | `cfg[0x2a,0x29,0x2b,0x26,0x27]`, no validation                |

Driver names for MIB 0x51, from its own debug output — these **correct** the static analysis, which
had the first two swapped and called `[0x29]` a probe step:

```
v1 -> cfg[0x2a]  up_rate_class_num
v2 -> cfg[0x29]  down_rate_class_num
v3 -> cfg[0x2b]  hw_rty_limit
v4 -> cfg[0x26]  per rate hw_rty_limit
v5 -> cfg[0x27]  per rate probe hw_rty_limit
```

Live firmware state without any of this: `/proc/skwifid/chip1.sdio/wlan0` prints the per-peer TX
mode, rate, `psr` and `tx_failed`. That node is how the per-TID split was found.

## Reproduction

**Easiest on 2.4 GHz, with `stress-ng` running and Wi-Fi left idle.** All of these matter, and the
last one is easy to lose by accident:

| ingredient                         | why                                                                                                                                                                                                                                                          |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Wi-Fi idle** during the window   | no TX attempts, so no probe can reach `cfg[0x25]` attempts                                                                                                                                                                                                   |
| **CPU load** (`stress-ng --cpu 4`) | TX is a `SCHED_OTHER` workqueue while RX is `SCHED_FIFO`, so load starves TX specifically                                                                                                                                                                    |
| ~~2.4 GHz~~                        | **withdrawn** — the first deterministic repro latched on _both_ bands (2462 @ −10 dBm and 5200 @ −20 dBm), and the originally reported failures were 5 GHz/80 MHz. The claim came from one 5 GHz miss, then every later A/B was pinned to 2462, baking it in |
| **control path off the radio**     | manage the box over ethernet; if ssh and daemons ride `wlan0` the link is never quiet                                                                                                                                                                        |
| **signal around −10 dBm**          | every reproducing run sat at −9…−12 dBm; at **0/+1 dBm** stock went **0/20**                                                                                                                                                                                 |

Measured on `wlan0`, 60 s idle samples: **201** tx packets with the box managed over Wi-Fi, **38**
with `systemd-resolved` and `systemd-timesyncd` stopped. At 3.4 packets/s the stimulus stopped
reproducing entirely (0/5).

Quieting the radio was **not sufficient**: at 28 packets/60 s, band pinned, `stress-ng` on all cores
with Wi-Fi idle, stock still went **0/20**. The box had meanwhile been moved much closer to the AP —
signal **0/+1 dBm**, against −9…−12 dBm for every run that reproduced. Position is therefore a live
variable, and an extremely strong signal appears to suppress the bug rather than cause it (which
also rules out the earlier "too close, receiver saturation" idea).

```sh
tools/idlestress-repro.sh          # associate, stress-ng with Wi-Fi idle 60 s, drop load, measure
```

Measure **after** the load stops — a latch has to persist without it. Verdict requires **legacy mode
AND** low throughput; throughput alone false-positives at 8–33 Mbps while a link settles.

```
2462 MHz, -11 dBm -> iw 6.0, 5.11 Mbps, legacy_rate: 60   LATCHED
5200 MHz, -20 dBm -> iw 600.4, 259 Mbps, mcs: 11          ok
```

Pin the band to remove AP steering as a confound:

```sh
wpa_cli -i wlan0 set_network 0 freq_list 2462
```

**What does not reproduce it** — each a useful negative:

| tried                                   | result                                                   |
| --------------------------------------- | -------------------------------------------------------- |
| CPU load **with** traffic running       | 85–90 Mbps, no latch — the traffic supplies the attempts |
| MMC/SDIO IO load (raw reads, 4 jobs)    | 90 Mbps, no latch                                        |
| reassociation loops                     | 1 hit in ~19, then 0 in ~130                             |
| firmware cold starts                    | 0 in ~40                                                 |
| BE flow held across association         | 0 in 12                                                  |
| induced failures at a raised rate floor | 0 in 4                                                   |

Other harnesses: `tools/triage-latch.sh` (AC sweep, UDP, small-MSS, rate-floor sweep with `psr`
readback), `tools/latchdiag.sh` (per-TID check plus a 12-minute soak with association events
counted), `tools/idle-repro.sh` (idle without CPU load — works, less reliably).

**Measure with `iperf3 --bind-dev wlan0` and check `/sys/class/net/*/statistics/tx_bytes`.**
`-B <wifi-ip>` does not force the interface; every earlier number taken that way is void.

## Patching is cheap here

- **No checksum to rebuild.** The image is raw Cortex-M code: offset 0 is the vector table, there is
  no header, no trailer and no checksum field, and no sidecar checksum file. The host driver
  computes its own CRC-16 (`crc_16_l_calc`, `iram_crc_val`/`_offset`/`_en`) over the buffer it
  downloads, so it covers patched bytes automatically. Zero CRC log lines across ~40 reloads,
  patched and stock.
- The board-suffixed firmware names are **symlinks**. There are two real files:
  `/usr/lib/firmware/SWT6621S_IRAM_SDIO.bin` and
  `/usr/lib/firmware/seekwave/SWT6621S_IRAM_SDIO.kickpi,k3b.bin`. Resolve before patching.
- The firmware **CRC is not enforced** — a deliberately corrupted byte loaded and ran.
- The loaded image is board-specific: `SWT6621S_IRAM_SDIO.h96max-zx,rk3518-tvbox.bin`, in
  `/lib/firmware` _and_ `/lib/firmware/seekwave`.
- Modules reload in place in ~40 s, no reboot, and that reverts any runtime write.
- Recovery net on the box: `/root/fw-backup`, `/usr/local/sbin/fw-restore`, `fw-guard.service`.

## Secondary defects, real but not this symptom

- **Signed-char overflow in the probe backoff.** `cVar3 = (char)(1 << exp) + ctx[0x1a9]` at 34151
  has no clamp on the sum; `exp` saturates at 6 so each failure adds up to +64. From 100 a further
  failure yields −92. The suppression test is `!= 0`, so a negative value still suppresses, and the
  decrement walks it further from zero.
- **`rc_init` never clears per-rate stats** (`+0xbc..+0x19b`); only STA-delete does. After a rebuild
  that shrinks the ladder a stale slot can win. `FUN_0012c478` clamps chain[1..6] but not chain[0],
  so the STA can report `rate_table[0]` = 1 Mbit/s DSSS.
- **Ascending chain when `cur == 0`** — `FUN_0012c478` uses one variable as both sentinel and
  position.
- **Copy/paste defect** at 35022-26: the +3 dB test reads `+0x1a6` while the +20 dB test and the
  store use `+0x1a7`.
- **`cfg[0x2d]` incremented per first-time peer init, never decremented** — after the second peer
  ever registered, tuned per-slot retry counts are permanently overwritten by defaults.
- Division by zero at 34436/34506 (`/ ctx[0x19c]`) when a window elapses with no TX attempts.

**RX has no rate control here.** The RX rate is the AP's choice; this chip only reports it. That is
why RX holds MCS 10–11 while TX collapses.

## Contents

| Path                                     |                                                                               |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `EXPERIMENTS.md`                         | what was established on hardware, in order                                    |
| `analysis/agent-1-rc-init-and-latch.md`  | `rc_init` and the `+0xa4 == 0` latch, verbatim                                |
| `analysis/agent-2-rate-ladder-module.md` | module map, struct layout, ladder mechanics, verbatim                         |
| `data/rate-table.txt`                    | the 57-entry global rate table, decoded                                       |
| `data/memory-map.md`                     | load addresses, struct layouts, function map                                  |
| `decomp/decomp-iram.c`                   | Ghidra decompilation, 1754 IRAM functions                                     |
| `tools/`                                 | repro, triage, disassembly, image patch, live memory write                    |
| `patches/`                               | **the fix** — `0002` (shipped, upstreamed), `0003` logging, `0001` superseded |
| `wifi-latch.md`                          | mechanism, evidence, and what a firmware fix would need                       |
| `WORKLOG.md`                             | dated lab notebook, oldest work at the bottom                                 |
| `bench/wifi_latch_repro.sh`              | the reproducer                                                                |

Both `analysis/` reports predate the per-TID finding and are kept verbatim as sources. Where they
conflict with this README, this README is the measurement.
