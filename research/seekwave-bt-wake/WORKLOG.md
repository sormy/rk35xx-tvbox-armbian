# Worklog — BT remote wake on the H96 Max 3518D

Dated history, wrong turns included. The result and the current state live in `README.md`; this is
what was actually done and in what order.

## 2026-09-05 → 09-07 — finding the faults

Started from "the box will not stay asleep". Four faults found in sequence, each one hiding the
next:

1. `xhci-hcd` failing `platform_pm_suspend` with -110, aborting suspend outright. Ours: the USB3
   graft left the SuperSpeed half present and unclocked. Reverted.
2. The SDIO suspend handshake being skipped every time — `send_host_suspend_indication()` samples
   the chip's traffic GPIO once, and suspend generates traffic of its own. Patch `0005`.
3. The remote hunting to reconnect ~3 s after the core's suspend-time disconnect.
4. Authenticated Payload Timeout Expired capping sleep at 30 s, then 655 s.

Bluetooth could not wake the host at all until `0004` gave the driver an `hdev->wakeup` callback,
and even then the accept list stayed empty because the kernel refuses to accept-list a device whose
IRK it holds while LL privacy is off. `rk35xx-bt-wake` strips the IRK.

**Wrong turns in this stretch:**

- `skw_sdio_suspend_adma_cmd: timeout gpioin value=1` read as a failing handshake. It is an
  unconditional log line; "timeout" is in the format string. A whole diagnosis was built on it.
- "Not Wi-Fi" concluded from a single 6.1 s sample against a 0.45–60 s spread.
- "ssh unreachable" read as "asleep" more than once. Only on-box evidence counts.
- Suspend evidence written to `/tmp`, which a power cut wiped; the empty file was then read as "it
  never woke".
- A ✅ on suspend called from three cycles with a human pressing to wake.

## 2026-09-07 — the LED fact that broke two analyses

Recorded that all LEDs go dark in suspend. Wrong: red holds. Owner's observation corrected it, and
both LEDs off turned out to be a state **no software here produces** — so an incident previously
read as "suspended and never woke" was a hang. Two conclusions withdrawn.

## 2026-09-08 — the quirk, and what it exposed

`0006` (`HCI_QUIRK_NO_SUSPEND_NOTIFIER`) stops the disconnect and so removes fault 3. That exposed
the rest: 28.3 s with the quirk alone, 3598 s once event mask page 2 was cleared, 4422 s with
Disconnect Complete masked too.

Then the 4422 s configuration was shipped and **bricked the wake**: 19.6 h asleep with zero
Bluetooth packets and no keypress able to reach it. Cause found in the trace — the host re-enables
accept-list scanning _as a consequence of_ Disconnect Complete, so masking that event means scanning
never comes back. Half of a two-part sequence had been masked.

**Wrong turns:**

- Shipped on one good run, bundling a verified change (page-2 mask) with an unverified one
  (Disconnect Complete mask) in a single deploy.
- The unverified half had only ever been tested as a manual `hcitool` command applied while awake
  and left in place. The driver applies it at `PM_SUSPEND_PREPARE` and restores on resume. Treated
  as equivalent; they are not.
- `bt-trace.service` ran `btmon -w` without redirecting stdout. `btmon -w` also decodes to stdout,
  so the journal filled to its 20 M cap and rotated away every `PM: suspend` record from the boot
  that failed. The diagnostic destroyed the evidence it existed to collect.

## 2026-09-09 — the hourly drop is the remote

Raised the stored supervision timeout 3000 → 32000 ms (BlueZ applies it at connection setup;
verified in-trace). Slept 3649.7 s against 3598.3 s — no change to the hour, but the disconnect
reason moved from `Connection Timeout (0x08)` to `LL Response Timeout (0x22)`. A 10× longer timeout
only changed which timer fired first, so the remote genuinely stops responding after ~1 h. Firmware
behaviour, unreachable from the host.

Also withdrawn here: an earlier claim that the stored-parameter edit "did not take". It did; the
reading came from a connection established before the edit.

## 2026-09-12 — the minimal design, and three closed doors

HID-over-GATT mandates a HID Control Point (`0x2A4C`): `0x00` means "host entering Suspend". Across
every capture it had **never been written** — BlueZ defines the UUID but puts the trigger behind an
opt-in backend. So the remote had always believed the host was awake. Built `rk35xx-bt-suspend` to
write it, restored `0004`/`0005`, deployed, rebooted, tested end to end.

**Failed.** Two suspends, both ended at exactly 2.00 s by `ADV_DIRECT_IND`. Retested properly after
the owner pointed out the first attempt was weak — the hook wrote `0x00` and suspended 0.25 s later,
and "went quiet" had been measured on an already-idle link. Redone awake, 10 s delay, disconnect
forced by hand: still one advert, reconnected within 5 s. The remote accepts the write and ignores
its meaning.

Disconnect reason codes `0x13`, `0x15`, `0x16`: all hunt back, one advert each.

Controller-side filtering: `LE_Get_Vendor_Capabilities` answers with `filtering_support = 0`,
`max_filter = 0`. No APCF, no offloaded filtering.

**Near miss worth recording:** the gate test first reported "no HID Control Point exposed". That was
a bad regex — `bluetoothctl` indents object paths with a tab and the matcher anchored on `^/`. The
whole approach was nearly abandoned on it, before a raw attribute dump showed `00002a4c` present.

## 2026-09-12 (late) — the factory firmware runs, and changes nothing

Owner's hypothesis: we ship the KICKPI K3B chip images, not the factory ones, so every wake
measurement has been taken on firmware Android never used. Correct, and documented in
`firmware/common/seekwave-fw/README.md` — the swap was forced in August because the factory images
assert on one opcode, `BSPASSERT:hci_tl.c-386` at Read Local Supported Codec Capabilities, delivered
as a hardware error that ends init.

Wrote `0007`: the driver answers the three codec reads (`0x100b`, `0x100d`, `0x100e`) locally with
Unknown HCI Command, so they never reach the chip. `HCI_QUIRK_BROKEN_LOCAL_COMMANDS` would also
avoid them, by skipping Read Local Supported Commands entirely — but that zeroes the whole bitmap
and takes the event-mask and disconnect paths with it. Default off; gated on `skip_codec_reads`.

**It works.** With the factory images in `/lib/firmware` and the quirk set:
`answering codec read 0x100d locally`, `hci0 UP RUNNING`, chip version `0x5302`, Wi-Fi unaffected.
The factory chip code had been unrunnable under Linux since August and now is not.

**It does not help.** Suspend `165.49 → 167.64` = **2.16 s**, wake irq 66, `ADV_DIRECT_IND` in the
trace — indistinguishable from the K3B baseline of 2.00 s. The remote hunts, the host wakes.

Also worth recording: the factory image answers `LE_Get_Vendor_Capabilities` with **Unknown HCI
Command**, where K3B at least replies (reporting `filtering_support = 0`). So there is no offloaded
advert filtering on either image, and the factory one supports fewer vendor extensions, not more.

**Method note.** The swap was done by unloading `skw_sdio_lite` over ssh — which is the Wi-Fi
transport, so it cut the connection mid-operation and cost a power cycle. Everything after touched
`skwbt` only. A driver swap that takes down the only network path has to run detached, with a
self-revert on failure.

## 2026-09-13 — PMU wake gating, s2idle, and where the wakelock actually is

**Rockchip PMU wake config: no per-source gating, but two useful discoveries.**
`rockchip,wakeup-config = <0x11>` decodes against `include/dt-bindings/suspend/rockchip-rk3528.h` to
`RKPM_CPU0_WKUP_EN | RKPM_GPIO_WKUP_EN`. GPIO is one switch for every GPIO wake — no per-pin
granularity — so the BT wake cannot be filtered at this layer. Clearing it would remove BT wake
entirely. Candidate closed.

What the same header shows is switched **off**: `RKPM_HDMI_HDP_WKUP_EN`, `RKPM_HDMI_CEC_WKUP_EN`,
`RKPM_PWMIR_WKUP_EN`, `RKPM_GMAC_WKUP_EN`, **`RKPM_TIMER_WKUP_EN`** and **`RKPM_TIME_OUT_WKUP_EN`**.
The claim repeated throughout this investigation — that the board has no timed wake because it has
no RTC — is true of Linux's `wakealarm` and false of the PMU, which has its own timer that we simply
never enabled. That does not fix the remote, but a PMU timer wake would mean an unwakeable suspend
recovers itself.

**s2idle: no help.** `mem_sleep` offers `s2idle [deep]` and only `deep` had ever been used. Under
`deep` a wake IRQ forces a full resume; under `s2idle` the kernel can process the event and return
to idle if nothing marks a wakeup source. Tested: `PM: suspend entry (s2idle)` 1172.34 → exit
1174.45 = **2.11 s**, wake irq 66 — indistinguishable from deep's 2.00–2.16 s.

**That failure is informative.** If nothing had held a wakeup source, s2idle should have gone back
to idle. Something holds one, and the driver source says what: `skw_sdio_lock_rx_ws()` calls
`__pm_stay_awake()` from the **GPIO interrupt handler**, before anything knows what arrived —

```c
if (!skw_sdio->suspend_wake_unlock_enable) {
        skw_sdio_lock_rx_ws(skw_sdio);
}
```

An advertising report, an HCI event and a real HID keypress are identical at that point. The only
gate is `suspend_wake_unlock_enable`, a global flag that `0005` sets, not a per-packet decision. The
Wi-Fi side meanwhile reports `skwifi_cmd: 641 events, wakeup_count 0`, so that path does distinguish
activity from wakeup. This is the gap.

**Vendor GATT listener armed.** `vendor-listen.sh` subscribes to the notify halves of both
undocumented vendor services — `ae02` at `service0080/char0083`, `ae42` at `service004e/char0051` —
and records to a btmon trace. It writes nothing to the command halves: a write-only vendor attribute
is also the shape of an OTA control point, and the remote is the board's only input device.

## 2026-09-13 (later) — the wakelock theory is wrong, and why host-side filtering cannot work

Chased the wakelock gap and found the opposite of what was expected:

```c
static void skw_sdio_lock_rx_ws(struct skw_sdio_data_t *skw_sdio)
{
//	if (atomic_read(&skw_sdio->rx_wakelocked))
		return;                          /* unconditional */
	atomic_set(&skw_sdio->rx_wakelocked, 1);
	__pm_stay_awake(...);
}
```

The guard is commented out and leaves a bare `return`, so the function does nothing and everything
below it is dead code. **The driver never takes that wakelock.** The previous entry's "this is the
gap" conclusion is withdrawn; `skwifi_cmd: wakeup_count 0` was consistent with a no-op all along.

That is still a genuine defect worth reporting separately — nothing holds the system awake while the
RX path drains, so a suspend racing an in-flight packet can drop it — but it is not our problem.

**What our problem actually is.** The wake comes from the wake-enabled GPIO interrupt itself. A
wake-armed IRQ registers a system wakeup when it fires, before any code can look at what arrived.
That is why `s2idle` made no difference: it is not a wakelock keeping the box up, it is the wakeup
event being registered at IRQ time.

So the host cannot filter. It cannot see whether the interrupt carries an advertising report, an HCI
event or a keypress until it is already awake, and by then the wake has happened. The only layer
that could filter is the controller, and `LE_Get_Vendor_Capabilities` reports
`filtering_support = 0` on the K3B build and Unknown HCI Command on the factory images.

This is the architectural answer the whole investigation was circling: **with a shared host-wake
GPIO and no controller-side filtering, spurious BT wakes cannot be prevented from the host.** Every
approach tried — event masking, control point, reason codes, keep-link, s2idle, PMU gating, firmware
swap — was an attempt to filter at a layer that structurally cannot.

## 2026-09-13 (later still) — the BT firmware is not ours to patch

Went looking for the BT firmware to add controller-side wake filtering, with the Wi-Fi TX latch work
as precedent — Ghidra, `fwpatch.py`, no checksum to defeat.

**There is no BT image.** The IRAM blob is raw Cortex-M loaded at `0x00100000` (SP `0x00107f68`,
reset `0x00104725`), uncompressed, 648 strings, and every source path in it is
`connectivity/wifi/...`. The single Bluetooth string in the whole image is `sdio_slv_bt_drv.c`, the
SDIO slave transport. DRAM has no code strings at all. The BT driver downloads exactly one thing, a
**37-byte** `NVDS` blob, which is configuration.

`BSPASSERT:hci_tl.c-386` — the assert that forced the firmware swap in August — appears in none of
the blobs. Grepped every image in `stock/*/firmware/` and `firmware/common/seekwave-fw/` for
`hci_tl|hci_|lmp|bt_ll|le_ll`: one hit, and it is that transport file. So `hci_tl.c` is compiled
into code the host never supplies, and the BT stack lives in on-chip ROM.

That closes controller-side filtering for good, and retroactively explains two earlier results: why
`LE_Get_Vendor_Capabilities` reports `filtering_support = 0` (absent from a ROM nobody can update),
and why swapping to the factory images changed nothing about wake (those images are Wi-Fi code, not
BT).

Written up with the evidence in `firmware-map.md`.

## 2026-09-13 — s2idle selective wake: the filter works, the wake path deadlocks

Owner's idea, and the first approach that does not try to filter at a layer which structurally
cannot. Under `deep` the SoC resumes in hardware before any instruction of ours runs, so there is no
moment in which to decide. Under `s2idle` the CPU services the interrupt while the sleep continues
and `s2idle_loop()` only exits on `pm_wakeup_pending()` — that gap is the one place a decision can
be made anywhere in the system.

Built as two gated changes:

- `skw_sdio_lite.no_irq_wake` — drop the GPIO from the wake sources, but **only** when
  `pm_suspend_target_state == PM_SUSPEND_TO_IDLE`, re-armed on resume. In a deep suspend the flag is
  ignored, because dropping the wake there would just make the chip unable to wake the host at all.
- `skwbt` — classify in `btseekwave_rx_complete` and call `pm_system_wakeup()` only for ACL data (a
  HID report) or an LE advertising report (`0x3e` subevent `0x02`/`0x0d`). Payload-timeout expiry,
  disconnect and completed-packet counts are delivered to the host as normal and simply do not count
  as wakeups — nothing is masked, so there is no phantom-connection failure.

**Result: it sleeps through everything, and nothing wakes it.** Owner: "doesnt wake from remote,
sleeps well". The filtering half works — no configuration before this ever held a suspend at all.

**Why the wake half cannot work as written.** The RX thread gates on resume before reading:

```c
void skw_resume_check(void)
{
	while ((!atomic_read(&skw_sdio->resume_flag)) && (timeout++ < 20000))
		usleep_range(1500, 2000);          /* ~35 s, then gives up */
}
```

`resume_flag` is cleared in `skw_sdio_suspend()` and set only in `skw_sdio_resume()`. During s2idle
the thread spins waiting for a resume that our own filter is preventing, so the packet is never
read, never classified, and `pm_system_wakeup()` is never called. The classifier needs the resume
that the classifier is supposed to cause.

**And removing that gate is not enough.** Reading would need SDIO transfers against an MMC host that
`dpm_suspend` has already suspended. `MMC_PM_KEEP_POWER` keeps the _card_ powered, but the SDIO
suspend model assumes the host resumes before any transfer — out-of-band IRQ wakes the system, then
the driver talks to the chip. Doing it the other way round is not something the MMC stack supports.

So the design is sound and the platform does not permit it: the only layer that can classify a
packet is the one that cannot run until after the wake it is meant to decide about.

A concrete path exists if anyone wants it: hold a PM reference on the MMC host across s2idle so the
controller stays usable, drop the `skw_resume_check()` gate in that state, and let the RX thread
run. That is a much larger change to shared SDIO code, with Wi-Fi riding on the same transport.

## Rejected by the owner

Suspending only once the remote has idle-disconnected on its own. It would work — the remote is
provably quiet after its own drop, and a keypress still wakes the box — but it means the box cannot
sleep for about an hour after last use, which defeats the point of a power button.

## Open leads

- **`s2idle`.** `mem_sleep` offers `s2idle [deep]` and only `deep` has ever been used. Under `deep`
  any wake IRQ forces a full resume; under `s2idle` the CPU wakes, the stack processes the event,
  and the system can return to idle if nothing marks a genuine wakeup source. The reconnect might be
  absorbed while a keypress still gets through. Untested.
- **A gap in the Seekwave driver.** `skwifi_cmd` shows 641 events with `wakeup_count = 0`, so the
  driver already separates "activity" from "wakeup". Whether the BT path makes that distinction at
  all — or pulls host-wake for every HCI event indiscriminately — has not been read out of the
  driver source.
- **The vendor GATT channels.** `ae01`/`ae02` and `ae41`/`ae42` are write/notify pairs, the shape of
  a proprietary command protocol. Undocumented, and a write-only vendor attribute is also the shape
  of an OTA control point, so blind probing risks bricking the only input device. Passive listening
  on the notify halves is the zero-risk first step.

## 2026-09-13 — the s2idle blocker was misidentified, and the real one is the interrupt core

Went back over the previous night's s2idle attempt before writing any more code, because the box
behaved exactly as a working filter would and that was too convenient.

`0008` disabled the chip's wake arming with `disable_irq_wake()`. That does not make an interrupt
filterable. `suspend_device_irq()` in `kernel/irq/pm.c` has three outcomes, and dropping the wake
arming moves the line from the second to the third:

- `no_suspend_depth` set: line stays live, handler runs while asleep, wakes nothing.
- wake-armed: `irq_pm_check_wakeup()` disables the line and wakes the system; **handler never
  runs**.
- neither: `IRQS_SUSPENDED` and `__disable_irq()`; handler never runs, nothing wakes.

So the box was not filtering anything — the interrupt was masked outright for the whole sleep. The
`skw_resume_check()` finding was real but it is the fourth obstacle, not the first; the RX thread
was never reached. `Documentation/power/suspend-and-interrupts.rst` names the right flag:
`IRQF_NO_SUSPEND`, set at `request_irq()` time, and never together with `enable_irq_wake()`.

Traced the rest of the path rather than guessing again:

- `dpm_suspend_noirq()` runs before `s2idle_loop()`, and it calls `suspend_device_irqs()` first, so
  any bookkeeping that has to beat it must happen in `->suspend` or `->suspend_late`.
- SDIO1 is `dw_mmc`. `dw_mci_rockchip_dev_pm_ops` is
  `SET_SYSTEM_SLEEP_PM_OPS(pm_runtime_force_suspend, pm_runtime_force_resume)`, and
  `dw_mci_runtime_suspend()` drops `ciu_clk` and — the node being `non-removable` — `biu_clk` too.
  Both are plain gates in `clk-rk3528.c`, flag `0`, not `CLK_IS_CRITICAL`.
- A runtime-PM reference does not stop it: `pm_runtime_force_suspend()` calls the callback whatever
  the usage count. The node carries `no-sd` and `no-mmc`, so `dw_mci_rockchip_probe()` leaves
  `use_rpm = false` and never enables runtime PM — which is why the clocks are simply always on in
  normal use.
- Completions come from `dw_mci_interrupt`, and `dw_mmc-pltfm.c` sets `host->irq_flags = 0`, so that
  line is neither `IRQF_NO_SUSPEND` nor a wake source and is masked for the whole sleep. A second
  action with `IRQF_SHARED | IRQF_NO_SUSPEND` is refused with `-EBUSY`; `__enable_irq()` refuses on
  a suspended line by design. Incrementing `no_suspend_depth` through the exported `irq_to_desc()`
  is what is left, and it is the ugliest part of this.

Checked the things that would have been fatal and are not: the RX thread has no `set_freezable()`,
so it is not frozen; `mmc_card_suspended()` is never consulted in the transfer path;
`timekeeping_suspend()` is `deep`-only so the dw_mmc timeout timers still fire;
`skw_sdio_lock_rx_ws()` is still the no-op it was; `net/bluetooth` registers no wakeup source of its
own; `port->rx_submit()` calls the BT driver directly from the RX thread.

Wrote `s2idle-feasibility.md` with the full trace and `0009` with the implementation. `0009`
supersedes `0008` and the two must not both be applied. **It has not been built or run** — the box
stopped accepting the ssh key partway through the day (it answers on 192.168.1.238, OpenSSH 10.0p2,
host key unchanged, and rejects both keys), so nothing could be compiled or tested.
`CONFIG_MMC_DW=y` in the Armbian config, so no part of this can be worked around with a patched
in-kernel module either — every piece had to stay inside the two out-of-tree modules.

## 2026-09-13 — `0009` built and running on the box

Box access was the morning's obstacle and it was my mistake: the login is `art`, not `root`.
`h96max-3518d` resolves to 192.168.1.238, MAC `fe:fd:fc:d8:87:b9`, which is the locally-administered
address the `.link` file generates.

`0009` did not compile as written. `irq_to_desc()` is exported only under
`CONFIG_KVM_BOOK3S_64_HV_MODULE`, which the earlier source read missed, and `modpost` rejects the
module with `"irq_to_desc" undefined`. `irq_get_irq_data()` is `EXPORT_SYMBOL_GPL` and
`irq_data_to_desc()` is a header inline, so the descriptor is still reachable. With that swap the
build is clean — no errors, no warnings in either patched file.

Two findings while setting up:

- **`/usr/src/seekwave-swt6621s-1.0.0` on the box carries only `0002`-`0005`.** The running modules
  were built from a scratch tree that no longer exists. A rebuild from `/usr/src` therefore drops
  `0007` and takes `hci0` down, because this box runs the factory firmware. Built in
  `/usr/src/seekwave-s2idle` instead and left the canonical tree alone.
- **`adc-keys` cannot wake this box.** `drivers/input/keyboard/adc-keys.c` never calls
  `device_init_wakeup()`, `evdev` raises no wakeup event of its own, and the node's only key is
  `linux,code = <0x57>`, KEY_VOLUMEUP. Polling continues under s2idle so a press is still _seen_,
  but nothing ends the sleep. That closes the open question about a cheap physical wake: there isn't
  one.

Deployed with a rollback net, because `wlan0` is the box's only route in and it rides the same
driver: previous modules copied to `/root/skw-backup`, and a boot-time oneshot that restores them
and reboots if the box ever comes up without a default route.

Running config: `s2idle_wake_filter=1`, `keep_link_suspended=1`, `skip_codec_reads=1`,
`mem_sleep=s2idle`.

First run: **the box held the suspend for over 31 minutes.** The unfiltered baseline on this board
is a wake about two seconds after every suspend. The remote was disconnected at the time — it drops
after an hour idle and the box had been up nine hours — so this run tests the filter, not the wake.

## 2026-09-13 — the mechanism is proven; what remains is policy

Instrumented the driver after three blind runs failed for want of a stimulus, and the counters
settled it. A real s2idle suspend, remote in hand:

```
601.099  PM: suspend entry (s2idle)
601.177  skw_sdio_suspend: s2idle filter armed, mmc irq 55
601.192  skw_sdio_suspend_late: force_resume=0, unmasking mmc irq 55
602.761  s2idle rx: type=0x04 evt=0x05 sub=0x00 size=7  worthy=0
602.762  s2idle rx: type=0x04 evt=0x0E sub=0x01 size=7  worthy=0
602.765  s2idle rx: type=0x04 evt=0x3E sub=0x0D size=29 worthy=1
602.798  skw_sdio_resume: s2idle filter: 6 chip irqs, 0 bt packets seen while asleep
602.909  PM: suspend exit
```

Six chip interrupts taken **while asleep**, read over SDIO by the RX thread, classified, and one of
them ended the sleep. All four obstacles are cleared: `IRQF_NO_SUSPEND` keeps the handler running,
`pm_runtime_force_resume()` returns 0 so the SDIO clocks are back, the unmasked controller interrupt
completes the transfers, and the classifier judges each packet. `Disconnect Complete` was refused a
wake and an Extended Advertising Report took one, which is exactly the programmed policy.

`0 bt packets seen while asleep` is an instrumentation bug of mine, not a finding — the counter
lives in the SDIO module and only the BT module can see the packets. The `s2idle rx` lines carry it.

**What is left is not mechanism.** The box wakes 1.7 s after suspend because the link drops and the
remote re-advertises, and an advertising report is what a keypress also looks like. This is fault 3
in a new place: no longer "the host disconnects at suspend", since the quirk is active
(`keep_link_suspended=Y`), but something still tears the link down 1.58 s in. The reason code was
not captured — the debug print shows `buf[3]`, which is the status byte for a non-LE event, not the
reason at `buf[6]`.

`Opcode 0x2041 failed: -16` / `start background scanning failed: -16` appears after the disconnect.
That is `LE Set Extended Scan Parameters` refused while a scan is already enabled, the same
`Command Disallowed` this controller returns to raw HCI. Benign here — an advertising report arrived
1.6 ms later, so scanning was live.

Also observed: `HandlePowerKey=suspend` is still what the box runs, against `ignore` in the repo.

## 2026-09-13 — proven, and reverted: the implementation destabilises the box

Added `wake_grace_ms` so the reconnect hunt that follows suspend entry stops counting as a keypress,
rebuilt, and handed the box back for a real test. The owner's report: trouble entering sleep,
trouble leaving it, and at some point an unprompted reset.

Reverted immediately — the modules the box ran all morning restored from `/root/skw-backup`,
`mem_sleep` back to `deep`, `s2idle_wake_filter` dropped from `modprobe.d`, the rollback unit and
every test script removed. Verified healthy afterwards: `hci0 UP RUNNING`, `wlan0` up,
`skip_codec_reads=Y`, and no `s2idle` parameter present, which is how you can tell the old module is
the one loaded.

The forensics do not name the fault and the timestamps cannot be trusted — `fake-hwclock` makes the
journal report "Realtime clock jumped backwards" and two boots of two seconds each that are
artifacts, not crashes. The last kernel log before a suspected reset ends in an orderly
`btseekwave_close`, which is a reboot, not a hang.

What is real, and was visible on every single s2idle resume:

```
rockchip-pm rockchip-suspend: Runtime PM usage count underflow!
```

Never present in `deep`, present in every s2idle run once the filter armed. That is a genuine PM
refcount imbalance, and the patch takes exactly two liberties that could cause one: it drives
another driver's device through `pm_runtime_force_resume()`/`pm_runtime_force_suspend()` across a
suspend, and it increments an interrupt descriptor's `no_suspend_depth` behind the interrupt core's
back. The feasibility write-up called the second of those the part that should give anyone pause. It
was right, and the balance argument in it — that the pairing is symmetric so the PM core sees the
state it created — is now contradicted by the box.

So the result stands split, and both halves are worth keeping:

- **The mechanism works.** Six chip interrupts serviced while asleep, read over SDIO, classified,
  `Disconnect Complete` refused a wake and an advertising report took one. That is not inference.
- **The implementation is not safe to run.** It is kept in `0009` as a proven-but-unsafe result, not
  as something to ship. Anyone picking it up starts by explaining the underflow.

Not chased, and still open: the link drops 1.58 s into the suspend even with
`keep_link_suspended=Y`, and the disconnect reason was never captured because the debug print dumps
`buf[3]`, the status byte, rather than `buf[6]`.

## 2026-09-13 — the underflow is the platform's, not the patch's

Ran the control that should have come first: a plain s2idle suspend with the original modules, my
patch not loaded at all.

```
loaded module has s2idle param: 0
PM: suspend entry (s2idle)
rockchip-pm rockchip-suspend: Runtime PM usage count underflow!
PM: suspend exit
```

So the warning has nothing to do with the PM bracket in `0009`, and the write-up blaming it was
wrong. The cause is in `drivers/soc/rockchip/rockchip_pm_config.c`:

```c
suspend_state_t suspend_state = get_mem_sleep_current();   /* s2idle -> PM_SUSPEND_TO_IDLE = 1 */
enum rk_pm_state state = suspend_state - PM_SUSPEND_MEM;   /* 1 - 3, enum is unsigned */
if (state >= RK_PM_STATE_MAX)
	return 0;                                          /* always taken under s2idle */
...
return pm_runtime_resume_and_get(dev);                     /* never reached */
```

`pm_config_complete()` then calls `pm_runtime_put_sync(dev)` unconditionally, so every s2idle cycle
puts without a get. The warning is the harmless half.

The harmful half is the early return. `SUSPEND_MODE_CONFIG` and `WKUP_SOURCE_CONFIG` are the SMC
calls that hand ATF this board's `rockchip,sleep-mode-config` and `rockchip,wakeup-config = <0x11>`,
and under s2idle neither is ever sent — ATF gets `LINUX_PM_STATE` and nothing else. Suspend-to-idle
on this vendor kernel runs with the firmware's suspend and wake configuration unapplied. That is a
far better candidate for "trouble entering, trouble leaving, and a reset" than anything in `0009`,
and it is present with or without it.

`CONFIG_ROCKCHIP_SUSPEND_MODE=y` in the Armbian rk35xx-vendor config, so it is built into the
kernel. An overlay box cannot ship a fixed version of it, which puts the whole s2idle route behind a
kernel change rather than behind anything in this repo.

Corrected in the README and in the `0009` header. The patch stays unshippable, but for the
platform's reason and not for the one previously written down.

## 2026-09-13 — correcting the correction: the rockchip bug explains nothing user-visible

The previous entry claimed the early return in `pm_config_prepare()` matters because ATF never
receives `SUSPEND_MODE_CONFIG` or `WKUP_SOURCE_CONFIG` under s2idle. That is wrong. Those SMC calls
configure a suspend ATF itself performs, and `suspend_enter()` only reaches `suspend_ops->enter()`
on the deep path:

```c
if (state == PM_SUSPEND_TO_IDLE) {
	s2idle_loop();
	goto Platform_wake;
}
...
error = suspend_ops->enter(state);
```

Under s2idle the firmware never suspends, so the skipped configuration is moot, and so are the
regulator on/off lists the same early return bypasses. What is left of the bug is the unbalanced
`pm_runtime_put_sync()` in `pm_config_complete()`, which `rpm_drop_usage_count()` undoes on the
spot. Cosmetic. Worth an upstream patch, worth nothing to this board.

The control run is also weaker than it was written up as. It used `pm_test=platform`, and
`suspend_test(TEST_PLATFORM)` returns before `s2idle_loop()`, so it never entered the idle path at
all. It proves the underflow originates in `->prepare`/`->complete` and is present without `0009`.
It does not show that real suspend-to-idle is stable on this board without `0009`.

So the instability stays unattributed, and the two liberties in `0009` — driving another driver's
device through `pm_runtime_force_resume()`/`pm_runtime_force_suspend()`, and incrementing an
interrupt descriptor's `no_suspend_depth` — remain suspects. Establishing that would need a real
s2idle suspend with the stock modules, which needs a wake source this board does not have; the only
honest way to get one is a second box or a serial console.

## 2026-09-13 — the box was suspending itself the whole time

After the revert the box went to sleep and could not be woken, which needed another power cut. The
reverted state is stock modules in `deep`, and in `deep` nothing on this board can wake from BLE —
that is the documented gap, not a regression. The question is what suspended it.

`/etc/systemd/logind.conf.d/zz-rk35xx-powerkey.conf` on the box read `HandlePowerKey=suspend`. The
repo's copy of that same file has said `ignore` since the power-key rework. The change was never
deployed, and it was noticed hours earlier in this session and not acted on.

So the remote's power button dropped the box into a suspend nothing could leave, on every press.
That is a confounder across today's testing: "unreliably going to sleep and waking" is what a power
key that suspends looks like when the wake path is the thing under test. It does not explain
everything — the s2idle runs had their own instability with the filter loaded — but any run where a
press was involved has two possible causes, not one, and cannot be attributed cleanly.

Deployed the repo's file and restarted `systemd-logind`. The box cannot now suspend itself, which
removes the confounder and the stranding risk from every future test on this board.

**Deploy drift is worth checking first, not last.** The box also carries `0002`-`0005` in `/usr/src`
while running modules built from `0002`-`0008`, and factory firmware against a repo that ships K3B.
Three divergences between repo and board, all found by accident.

## 2026-09-13 — back to deep, with a narrower target

s2idle parked. The deep path was abandoned for a correct reason — nothing can filter a wake there,
because the SoC resumes in hardware before any instruction runs — but that is a reason not to
attempt _filtering_, and filtering is no longer what is needed. With `keep_link_suspended` holding
the link and page 2 cleared, this board sleeps 3598 s and exactly one thing ends it: the link dies
after about an hour and `Disconnect Complete` pulls host-wake. One event, once an hour, and that can
be stopped where it is produced. A masked event is never sent, so there is no traffic and nothing to
resume on.

`0010` does that, in two parameters because the second is only survivable with the first:

- `presuspend_scan` — at `PM_SUSPEND_PREPARE`, add the connected peer to the controller's accept
  list and start a passive scan. Both are necessary: scanning is off whenever the remote is
  connected, and the kernel builds the accept list from devices it is waiting to connect to, so a
  connected one is not on it. Filter policy is accept-list; "all" would make every advertiser in
  range a wake source.
- `mask_disconnect` — hide `Disconnect Complete` for the sleep, restore on resume, then reconcile:
  the host still believes the link is up and would ignore the remote's advertising, so the handle is
  probed with `Read RSSI` and a `Disconnect Complete` is synthesised into the stack if the
  controller has already forgotten it.

There is no command to read the event mask back, so the value restored on resume is the one the core
last wrote, snooped in the transmit path. Hardcoding this kernel's `0x3dbfd807fffbffff` would break
on any other.

Built clean, no warnings. Being tested in two steps, because the failure mode of the second is
another unwakeable box: step 1 arms the scan and masks nothing, which behaves exactly as today and
only proves the three arming commands succeed on this controller; step 2 adds the mask.

`LE Set Scan Parameters` is refused outright while a scan is enabled — that is what the
`Command Disallowed (0x0c)` seen during the s2idle diagnosis was, not a controller quirk — so the
arm disables scanning first.

## 2026-09-13 — step 1 earned its keep

Ran `0010` with `presuspend_scan=1` and `mask_disconnect=0`, which masks nothing and so behaves
exactly as the board does today. It caught two things.

**The accept list is populated while the remote is connected.** Measured, with `Connected: yes`:

```
74:cc:23:de:9d:33 (type 0)
```

The premise that the kernel strips a connected device from the list was wrong. The add in
`skwbt_arm_scan()` is therefore refused as a duplicate — `opcode 0x2011 failed: -22` — and is kept
only as insurance.

**The scan was never armed.** `opcode 0x200b failed: -16`, `LE Set Scan Parameters` answered with
Command Disallowed. Not because a scan was already running: the core uses the **extended** scan
commands on this controller, and the legacy and extended sets cannot be mixed. Once the core has
used the extended ones, the controller refuses the legacy ones outright.

That also explains the `Command Disallowed (0x0c)` hit repeatedly while trying to drive a scan by
hand with `hcitool` during the s2idle work, which was written off at the time as a Seekwave quirk.
It is plain spec behaviour.

Had step 2 run first, the mask would have been applied with no scan armed — which is exactly the
19.6 h unwakeable box, reproduced deliberately. The two-step split paid for itself on its first use.

Fixed by choosing the command set with `use_ext_scan(hdev)`, the same test the core uses, and
logging which path was taken along with the enable's status. Re-run:

```
accept-list scan for 74:cc:23:de:9d:33 (type 0): extended, enable ret 0
```

Scan armed, return code 0. Box slept 36 s and woke on a keypress. Step 2 — the same configuration
with `mask_disconnect=1` — is now running.

## 2026-09-13 — step 2: the board slept through the teardown

`presuspend_scan=1 mask_disconnect=1 keep_link_suspended=1`, deep suspend:

```
-- suspending at 14:17:52 --
-- returned after 5934s (15:56:46) --
remote: Connected: yes
accept-list scan for 74:cc:23:de:9d:33 (type 0): extended, enable ret 0
```

**5934 s — 99 minutes.** Every previous sleep on this board ended at about 3598 s, at the link
teardown, and the only thing changed here is that the event is masked. The teardown happened and the
host never heard it. The keypress that ended the sleep arrived as an advertising report on the
pre-armed accept-list scan, visible as `skw_sdio2_adma_parser: ch:2 len:41` in the resume.

That is fault B closed, and with it the last thing that ended a held-link sleep.

**The resync did not fire, and that was a defect in it.** After the wake, `bluetoothctl` reported
`Connected: yes`, `hcitool con` was empty and no HID input device existed — the phantom connection
the README predicted. `skwbt_resync_link()` probes the stale handle with Read RSSI and treats
`IS_ERR` as a reason to give up quietly, but `__hci_cmd_sync_sk()` returns `ERR_PTR(err)` for any
non-zero command status, so a handle the controller has already forgotten lands in exactly that
branch. The failure _is_ the answer. Fixed: an error now synthesises the disconnect, and all three
outcomes log.

Also added `settle_ms`, which is the other half of making the power button usable. The key sends
press and release about 360 ms apart, so suspending on the press leaves the release to arrive as
data on a held link and take the box straight back out - fault A, measured at 0.37 s. Waiting for
the link to be quiet for 500 ms before suspending consumes it first. `HandlePowerKey` restored to
`suspend`; testing the real gesture rather than `systemctl suspend` over ssh.

## 2026-09-13 — the first press after a reconnect, and why it bounced

Owner's report: works, except the first power press after the remote has just reconnected wakes the
box straight back; every press after that is fine. Eight cycles in one boot split it cleanly.

Cycle 1, 0.66 s, woken by `ch:2 len:41` — an advertising report — followed by
`handle 0x0012 probe failed (-107), synthesising the disconnect`. Cycles 2-8, woken by `ch:5 len:26`
— ACL data — each with `handle 0x0012 still live`. So seven of the eight were the owner's own
keypresses waking the box, which is the feature working; only the first was wrong.

`-107` is `ENOTCONN`, which `bt_to_errno()` maps from HCI status `0x02`, Unknown Connection
Identifier, and nothing else in `hci_sync` returns it. The failing command was the answer, so the
resync logic is sound.

The defect was upstream of it: `skwbt_pm_notify()` took `skwbt_le_conn()` — the host's belief — as
fact. After a masked disconnect the host can hold a handle the controller dropped long ago, which is
precisely the state just after the remote reconnects from idle. Arming a scan and a mask against
that handle leaves the remote free to advertise its way back in and end the suspend at once.

Fixed by running the same probe _before_ arming: a stale handle is corrected into the stack, the
reconnect is given `reconnect_ms` (3 s default), and what gets armed is a link that exists. With no
live link the suspend proceeds unarmed and unmasked rather than masking against nothing.

`settle_ms` was not at fault; it was never reached by this path.

## 2026-09-13 — the stale-handle fix was wrong, and reverted

Owner: worse and unreliable. Reverted to the previous build the same minute.

The change had been made off a single observation — one bounce where the host held a handle the
controller had dropped — and generalised into a pre-arm probe that synthesised a disconnect on _any_
probe failure and then looped HCI commands for up to three seconds at suspend entry. Both halves add
variance to a path that has to be dull, and neither addressed what the next log actually showed:

```
1975.010  PM: suspend entry (deep)
1975.028  accept-list scan ... enable ret 0          <- probe said the handle was live; armed normally
1976.386  adma_parser: ch:2 len:41                   <- advertising report
1976.512  handle 0x0012 is gone, synthesising the disconnect
```

No `stale at suspend` line, so the pre-arm check passed and did nothing. The handle was live when
the box suspended and **dead 1.37 s later**, with the remote already advertising. So the link is not
stale before the suspend — it dies during it, and the hunt that follows is what ends the sleep.

That is a different fault from the one that was "fixed", and the fix could not have helped.

**The open question, and a hypothesis worth one cheap test.** The 5934 s success had the link up for
78 s plus a 12 s settle before suspending. Every bounce has followed a power press made shortly
after the remote reconnected. So the suspicion is a freshly established link does not survive the
suspend handshake — `send_host_suspend_indication()` drops `gpio_out` and waits for the chip, and a
connection still negotiating may not survive that. `settle_ms` does not cover it: it tracks ACL
only, and connection setup is HCI events.

Testable without a build: connect the remote, wait 30 s, then press power. If that holds and an
immediate press does not, the requirement is link age, and the fix is to make the settle wait cover
all received traffic rather than ACL alone — or to refuse to arm until the link has been up for a
minimum time.

## 2026-09-13 — it works: the missing piece was a debounce on the link

Owner: works well; behaviourally it looks like a debounce. That is exactly what it is.

`settle_ms` was already waiting for the link to fall quiet before suspending, but it keyed on ACL
data alone. A link that has only just been re-established is busy with _events_ — connection
parameters, encryption, HID setup — so the wait sailed straight through the gaps between them, the
box suspended into the middle of the negotiation, the link died, and the remote's hunt was heard by
the very scan armed to hear a keypress. That is the 1.37 s bounce, and it is why pressing power
right after picking up the remote failed while a link already up for a minute did not.

Keying the wait on any received packet fixes it. Nineteen consecutive cycles:

```
4313.465  PM: suspend entry (deep)
4315.517  accept-list scan for 74:cc:23:de:9d:33 (type 0): extended, enable ret 0
4316.407  skw_sdio2_adma_parser: ch:5 len:26
4316.532  PM: suspend exit
```

Every wake is `ch:5` — ACL data, a real keypress. **Not one `ch:2` advertising report** anywhere in
the nineteen, so no link died and no hunt occurred. The 2.05 s between suspend entry and the scan
arming is the debounce doing its work.

Short sleeps, then: the board suspends on the remote's power key and wakes on any key, which it has
never been able to do.

**Not yet a verified fix — a candidate.** All nineteen cycles are short, and the 5934 s run that
proved the 1 h teardown can be slept through predates two of the changes now on the box: the resync
that treats a failed `Read RSSI` as the answer, and the settle wait keying on all traffic. The
resync is precisely what runs after a masked disconnect, so the long case has not been exercised on
this build at all. It has to be re-run before any claim is moved out of research.

**What this cost, and the lesson.** Three changes were made off single observations — the stale
handle path, its revert, and this — and only the last was supported by a pattern. The owner's "more
or less good with the remote already connected" was worth more than any of the theorising: it turned
one bounce into four consistent data points and pointed straight at link age. Characterise first,
then change one thing.

`0010` is still research, not shippable: it masks a core HCI event and drives the controller's scan
state behind the stack's back. Narrowing the mask to a single handle, if the controller can express
that, is the work that would make it a candidate for `patches/`.

## 2026-09-14 — the long sleep works; the resume left the controller deaf

Clean deploy via `rk35xx-update`, cold boot, then a long sleep: **27564 s — 7.65 hours** — ended by
an advertising report, with the resync synthesising the disconnect correctly. The masking half is
not in doubt.

What followed was: nothing. Nine suspend cycles in that boot and **none after the long-sleep
resume**. The box was not bouncing awake, it was never being asked to sleep, because the remote had
not reconnected and the power key therefore had no path to it. Missing from the log at resume is the
`input: Bluetooth remote Keyboard` enumeration that an earlier successful long sleep produced 0.4 s
after resume.

The state that explains it, measured while it was stuck:

```
remote:       Connected: no
input devs:   4 (the onboard ones only)
accept list:  74:cc:23:de:9d:33 (type 0)
device_list:  74:cc:23:de:9d:33 (type 0) 3
adv reports in 6 s: 0
```

The core had the remote accept-listed with auto-connect armed and believed a scan was running. The
controller was not scanning.

**Cause, and it is an ordering bug in `0004`.** `PM_POST_SUSPEND` restored the event mask,
synthesised the disconnect, and only then disarmed the scan. The synthesised event reaches the stack
asynchronously, so the core answers it by enabling a scan of its own — and the disarm landed after
that, switching off a scan the core thought it had just started. The core never re-enables what it
believes is already on, so nothing listened for the remote again.

Fixed by handing the scan back first and telling the stack second, so the core's reaction is the
last write. One reorder, and the comment above it says why, because the failure is silent:
everything downstream looks correct and the only symptom is a box that will not suspend.

**Worth noting what this cost.** A scan started behind the core's back has to be handed back before
the core is given any reason to touch it. That is the general shape of the risk in this patch, and
it is why it is not upstreamable as it stands.

## 2026-09-14 — the notifier blocks on `hdev->req_lock`, and that is the instability

Made the box keep its logs first, because every failure so far ended in a power cut and `/var/log`
was zram, synced only on clean shutdown. `armbian-ramlog` disabled, journald `Storage=persistent`
with `SyncIntervalSec=10s`. The next failure then left a trace, which is the only reason this entry
exists.

Also stopped disarming the scan at resume. `skwbt_arm_scan()` does disable → set params → enable
unconditionally, so where the core already had a background scan running we replaced it while the
core still believed its own was up; switching ours off at resume left the controller deaf. The log
confirms the change took: `opcode 0x2011` moved from `-22` (duplicate entry) on the first cycle to
`-16` (Command Disallowed) on every cycle after, which is what adding to an accept list _in use_
returns. Correct, and not the instability.

**The failure, from the trace.** Seven `PM: suspend entry`, six `PM: suspend exit`. The seventh
begins one second after the sixth resumed and logs **nothing at all** — no `accept-list scan`, no
`no LE link at suspend`, not even the page-2 failure line. All six good cycles logged those.

`pm_suspend()` prints "suspend entry" before the notifier chain runs, so the notifier was entered
and stopped before its first log. The first thing on that path that can block is:

```c
skwbt_wait_link_quiet();                                    /* bounded, settle_ms * 4 */
skb = hci_cmd_sync(hdev, HCI_OP_SET_EVENT_MASK_PAGE_2, …);  /* silent on success */
```

`hci_cmd_sync()` takes `hdev->req_lock` with a plain `mutex_lock`. The command carries
`HCI_CMD_TIMEOUT`; **acquiring the lock does not.** A second after resume the core is still running
its own `hci_cmd_sync_work` — reconnecting the remote, the RESUME ack — so the lock is held and the
notifier waits inside `PM_SUSPEND_PREPARE` with no bound.

That is the "worse when pressed often" the owner reported: the shorter the gap between a resume and
the next press, the likelier the notifier lands on a busy stack.

**Doing blocking HCI work in a PM notifier is the defect**, not any particular command. Two ways
out, smallest first: `mutex_trylock` on `req_lock` and skip arming when it is held — that suspend
goes unprotected and may wake early, but the box stays alive — or refuse to arm within some seconds
of a resume. Unprotected costs a wake; blocked costs a power cut, so the asymmetry picks the answer.

Not attempted yet. Three changes today were made on one observation each and two of them were wrong;
this one waits for a second trace.
