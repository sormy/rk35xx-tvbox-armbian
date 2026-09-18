# Seekwave SWT6621S — sleep and wake on the BT remote

Measured on the H96 Max 3518D, the only board here with no IR receiver, but the faults are in the
driver and the controller rather than the board. Suspend itself works: it enters `deep`, resumes
with the same `boot_id`, and survives past the watchdog window. **Waking it from the BLE remote is
what does not work.** Seven faults were found and six have working fixes, including the one that
ended every held-link sleep at 3598 s. The seventh is why none of this ships.

**Current position: parked.** Nothing here is wired into a build. `0004` is measured working — 27564
s asleep through the hour-long teardown, HID back 0.4 s after resume, nineteen consecutive short
cycles on the power key — and is not shippable, because a later suspend can hang before the
Bluetooth driver's PM notifier is entered at all and the box then needs its power pulled. The
remaining trace is in `WORKLOG.md`; the block is ahead of this driver in `suspend_prepare()`.

Long press stays `ignore`: it used to reach poweroff, which is one-way here, since BLE cannot wake a
powered-down controller.

The last piece was a debounce. `settle_ms` holds the suspend until the link has been quiet, and it
has to count _every_ packet: a link that has only just been re-established is busy with events —
connection parameters, encryption, HID setup — and a wait keyed on data alone sails through the gaps
between them, suspends into the middle of the negotiation, and loses the link. The remote then
hunts, and the hunt is heard by the very scan armed to hear a keypress.

## Why only this board

The R69 and H96 Max both suspend and wake fine — over IR. On those, Bluetooth is dead in suspend and
off, and only the IR receiver is armed as an ATF wake source; the dual-mode remote falls back to IR
whenever the BLE link drops, so BT wake was never needed and never worked there either.

This stick is the only board with no IR receiver fitted, which forces it onto the one path nobody
had ever made work. The faults below are not regressions — they are a path used in earnest for the
first time.

What that leaves:

- No RTC and no `wakealarm`, so nothing can bring the box back on a schedule.
- No IR receiver, so no second input path.
- Every wake arrives on `pm_wakeup_irq 66`, the SDIO host-wake shared with Wi-Fi.
- `dw_wdt_suspend()` gates the watchdog clock, so a box that will not wake needs the power pulled.

One wake source, no fallback, a hard recovery cost. That is why each failure below was expensive to
test.

## Fixed

**1. `xhci-hcd` fails `platform_pm_suspend` (-110), aborting suspend.** Our own USB3 graft:
`maximum-speed` plus a disabled `combphy` leaves the SuperSpeed half present and unclocked, and it
never halts. Graft reverted; this one ships.

**2. The SDIO suspend handshake was skipped every time.** `send_host_suspend_indication()` samples
the chip's "traffic pending" GPIO once, and suspend generates traffic of its own, so the one sample
it takes is the moment the line is most likely high. The chip was never told the host went down and
kept asserting the line until the wake-enabled interrupt resumed the box. Fixed in `0004`, parked
here.

**3. Wake ~3 s after every suspend.** `hci_suspend_sync()` disconnects every link, and this handset
answers with `ADV_DIRECT_IND` to reconnect. Waking on an accept-listed device's advert _is_ the
upstream design and cannot be filtered, because a keypress from a bonded remote sends the same PDU.
Fixed in `0004`.

**4. Wake at exactly 655 s, or 30 s at the default.** Authenticated Payload Timeout Expired. The bit
lives in event mask **page 2**, which `HCI_INIT` writes once and no suspend path revisits. Measured
exactly: the event fired **655.41 s after the last keypress**, against an `auth_payload_timeout` of
0xffff (655.35 s). Every keypress refreshes it. Fixed by clearing page 2, in `0004`.

**5. Bluetooth could not wake the host at all.** The driver never set `hdev->wakeup`, so
`hci_suspend_sync()` took its early return and armed no accept list. Fixed in `0004`.

Fault 5 has a second half that is **not** in the driver: the kernel refuses to accept-list a device
whose IRK it holds while LL privacy is off — `hci_le_add_accept_list_sync()` returns `-EINVAL` — so
the list stays empty. `rk35xx-bt-wake` here strips the IRK before bluetoothd reloads it.

## The two that took the longest

### A. The power key's own release, ~0.4 s

Press and release are ~360 ms apart. `logind` suspends on the press, and with the link held the
release lands on the far side and resumes immediately — 0.37 s of sleep against a 364 ms gap, in the
same trace as a 4422 s success entered over SSH.

`settle_ms` closes it by refusing to suspend until the link has been quiet, counting every received
packet rather than data alone: a freshly re-established link is busy with connection-setup events,
and a wait keyed on data sails through the gaps between them. What it cannot close is a report
arriving _after_ the wait — 0.44 s measured — because in `deep` nothing is running to ignore it.

### B. The link dies after ~1 h idle and the disconnect wakes the box

The remote stops answering after roughly an hour and the link is torn down; `Disconnect Complete`
then pulls host-wake. Why the remote stops is firmware behaviour and unreachable from the host.
Raising the supervision timeout only changed which timer fired first — 3000 ms gave 3598.3 s and
reason 0x08, 32000 ms gave 3649.7 s and reason 0x22 — so it is not RF margin.

Deep suspend cannot filter a wake, but filtering is not what this needs: it is one event, once an
hour, and a masked event is never sent, so there is no traffic and nothing to resume on.

**Masking alone does not work, and that is measured.** The host re-enables accept-list scanning as a
_consequence_ of that event, and scanning is off while a link is up:

```
> HCI Event: Disconnect Complete            #1959
< HCI Command: LE Set Extended Scan Params  #1960   Filter policy: Ignore not in accept list
< HCI Command: LE Set Extended Scan Enable  #1962   Extended scan: Enabled
```

Mask it and the scan is never armed: 19.6 h asleep with zero Bluetooth packets and nothing able to
wake it, recovered by a power cut.

`0004` arms the scan first, at `PM_SUSPEND_PREPARE`, while the link is still up — which the
controller allows, `LE Read Supported States` reporting _Passive Scanning State and Connection State
(Central Role)_. Two details decide whether it works at all:

- **The extended commands, not the legacy ones.** The core uses extended scanning here, the two sets
  cannot be mixed, and the legacy ones are then answered with `Command Disallowed`.
- **Filter policy accept-list, not "all"**, or every advertiser in range becomes a wake source.

The accept list needs no help: measured with `Connected: yes`, the kernel leaves the peer on it.

The phantom connection is real and handled on resume — the stale handle is probed with `Read RSSI`
and a `Disconnect Complete` synthesised when the controller has forgotten it. Unknown Connection
Identifier arrives as an `ERR_PTR`, so the probe failing _is_ the answer. Order matters there: the
scan must be handed back before the stack is told anything, or the core answers the synthesised
disconnect by enabling a scan that the disarm then kills, and nothing listens for the remote again.

## What mainstream does

Upstream's design — the ChromeOS "Handle system suspend gracefully" series — disconnects at suspend
and wakes on the bonded device's reconnect advert, aiming to "wake the system when a HID device
receives user input but otherwise not send events to the host". It assumes a disconnected peripheral
stays quiet; this one re-advertises in ~3 s. The common workaround in the wild is to disable BT wake
entirely, which is not available here because it is the only wake source.

Embedded vendors solve it in controller firmware (NXP AN12849): the chip decides what pulls
host-wake, so link maintenance never reaches the host. This Seekwave firmware pulls host-wake for
every HCI event it generates — and that last clause is the opening. **No firmware change was needed
here.** The host cannot inspect a packet and then decide whether to wake, but it can stop the
controller producing the packet at all, and the event mask is a core-spec command for exactly that.
What is genuinely absent is Android's APCF vendor extension: `LE_Get_Vendor_Capabilities` reports
`filtering_support = 0`, so _advertising_ cannot be filtered in the controller. Events can.

That distinction was missed for weeks, because the earlier conclusion that masking "is not the
answer" was written down as confident. The failure behind it had a fixable cause, and a confident
negative shut a door that was open.

`HCI_QUIRK_NO_SUSPEND_NOTIFIER` is also used off-label here. It exists for controllers that drop off
the bus during suspend and are re-probed on resume, such as Realtek USB dongles. Using it to keep a
link alive works only because it skips the entire suspend sequence — which is where faults 3, 4 and
B come from.

## What is here

**Nothing in this directory reaches a build.** `fetch-seekwave-src.sh` globs only
`patches/seekwave-swt6621s/*.patch`, and none of these live there.

- `0004` — the whole sleep/wake fix, six faults in one patch because the sequence only works whole.
  Measured working; parked on the seventh fault below.
- `0008`, `0009` — filtering wakes under suspend-to-idle rather than preventing them. The
  classification is proven on hardware, but it destabilised the box and s2idle is not a supported
  path on this vendor kernel. `s2idle-feasibility.md` carries the full trace. `0004` supersedes
  both.
- `rk35xx-bt-wake` + `bt-wake.conf` — drop the remote's IRK at bluetoothd start, because
  `hci_le_add_accept_list_sync()` refuses a device whose IRK it holds while LL privacy is off, which
  governs the kernel's own background scan. A driver cannot replace this: `hci_remove_irk()` is not
  exported and bluetoothd owns the persistent copy.
- `skwbt-bt-wake.conf` — the modprobe opt-in that turns `0004`'s four parameters on.
- `rk35xx-bt-suspend` — the `system-sleep` hook that writes the HID Control Point and waits out a
  held power key. Proven to change nothing, because the remote ignores the control point.
- `gate-test-hid-control-point.sh`, `vendor-listen.sh` — the probes behind those findings.
- `firmware-map.md` — why the BT stack is ROM and no firmware patch was on the table.

## The seventh fault, unsolved — a suspend that hangs before this driver runs

A suspend can reach `Filesystems sync` in `enter_state()` and never reach
`Freezing user space processes`. The box is then neither running nor asleep and needs its power
pulled. Traced with the notifier logging its own entry: `pm: prepare, settling` — the first
statement in `skwbt_pm_notify()` — **never prints**, so the block is ahead of this driver in
`suspend_prepare()`, in `pm_prepare_console()` or a notifier registered earlier.

It is not load-dependent in the way it first appeared: one occurrence followed the previous resume
by a second, another by eighteen idle minutes.

`swt6621s_wifi` registers its notifier before `skwbt` and so runs first; its `PM_SUSPEND_PREPARE`
calls `skw_wowlan_prepare_handler()`, which calls `cfg80211_stop_iface()` for every interface while
holding `spin_lock_bh(&skw->vif.lock)`. That call only queues work and should not block, which is
why it is a suspicion and not a conclusion. The next step is the blocked-task backtrace, not another
theory — three causes were named from missing evidence during this work and each was wrong.

## Failed — tuning the timers

- **`auth_payload_timeout=65535`** — defers fault 4's event to the spec maximum instead of removing
  it. Superseded by clearing page 2.
- **Reducing the LE Ping rate to make B rarer** — 655 s pings versus 30 s gave 3598 s versus 3650 s
  of sleep, so ping rate is not the mechanism.

## Failed — the HID Control Point

HID-over-GATT mandates a HID Control Point, UUID `0x2A4C`: the host writes `0x00` for "entering
Suspend", `0x01` for leaving, and a device that honours it drops its scan rate and stops driving the
link. Nothing in a stock stack ever writes it — BlueZ defines the UUID but puts the trigger behind
an opt-in backend, because a UPower suspend signal arrives after the connection is already gone. So
for this whole investigation the handset believed the host was awake, including while it hunted to
reconnect and while it timed out at the hour. That looked like the missing piece.

**It is not. This remote ignores it.** Measured 2026-09-12 with `rk35xx-bt-suspend` writing `0x00`
from the `pre` hook, confirmed in the journal, on a link that was up at suspend entry:

```
> HCI Event: LE Meta Event — LE Extended Advertising Report
    Legacy PDU Type: ADV_DIRECT_IND (0x0015)
    Address: 74:CC:23:DE:9D:33
```

Two runs, both ended by that advert **2.00 s** after suspend entry. The characteristic is present at
`service0023/char004c`, the write returns no error, and the behaviour is unchanged: the remote still
hunts to reconnect the moment the core disconnects it.

Exposing `0x2A4C` and ignoring the value is common on cheap handsets, which is why presence was
never taken as proof. The write costs nothing and is harmless, but it fixes nothing here.

A second observation from the same capture: `Authenticated Payload Timeout Expired (0x57)` fires
every ~31 s **while awake**, so the remote does not answer LE Ping at all — not only during suspend.
That is the same root as fault B, visible without suspending.

## Failed — the disconnect reason code

The one asymmetry never explained: after the core's disconnect the remote hunts back in ~2 s, but
after its **own** ~1 h idle drop it goes quiet. Same disconnected state, opposite behaviour. The
reason code looked like the difference — `hci_suspend_sync()` uses
`HCI_ERROR_REMOTE_POWER_OFF (0x15)`, which a peripheral might read as "host left, reconnect".

Tested by disconnecting by hand, awake, and counting `ADV_DIRECT_IND`:

| Disconnect reason               | Result               |
| ------------------------------- | -------------------- |
| `0x16` Terminated By Local Host | hunts back, 1 advert |
| `0x15` Remote Device Power Off  | hunts back, 1 advert |
| `0x13` Remote User Terminated   | hunts back, 1 advert |

It reconnects within 5 s either way. The reason code is not the difference, and what is remains
unknown.

## Failed — controller-side advert filtering

Android defines vendor HCI commands for exactly this problem: `LE_APCF_Command` (opcode `0x157`)
filters advertising packets inside the controller, so the host is only woken for adverts that match.
If the chip supported it, a hunt advert could in principle be filtered while a keypress advert was
not.

`LE_Get_Vendor_Capabilities` (`0x153`) answers, and says no:

```
status 00   max_advt_instances 00   offloaded_RPA 00   scan_results_storage 0000
max_irk_list_sz 03   filtering_support 00   max_filter 00
```

**`filtering_support = 0`, `max_filter = 0`.** No APCF, no offloaded advert filtering of any kind.
Events are a different matter — the core-spec event mask is what `0004` uses.

## The remote's GATT, fully enumerated

Standard services offer nothing beyond the control point already tested: HID (`0x1812`) exposes only
`Report`/`Report Map`/`Protocol Mode`/`HID Control Point`, Battery and Device Information are
read-only, and GAP's Preferred Connection Parameters is informational.

`PnP ID` decodes to **VID 0x2B54, PID 0x1600** — the same pair the hwdb keymap matches on. No
documentation for that vendor ID was findable.

Three vendor services, and two of them are shaped like control channels:

- `0xae00` — `ae01` write-without-response, `ae02` notify
- `0xae40` — `ae41` write-without-response, `ae42` notify
- `ab5e0001…` — the Android TV voice service; `ab5e0002` write/read/notify, `ab5e0003`/`0004`
  notify. Documented, and audio-only: capability negotiation and voice streaming.

The `aeXX` pairs are the right shape for a proprietary command protocol — write a command, read the
answer on the notify half. **The protocol is undocumented and was not findable.** A write-only
vendor attribute paired with a notify is also the standard shape of an OTA control point, so
blind-probing risks putting the handset into firmware-update mode, unpairing it, or bricking it. It
is the only input device the board has.

The zero-risk step first: subscribe to `ae02` and `ae42` and log whether the remote ever volunteers
anything — on keypress, while idle, or before it drops the link at the hour. That reveals the
protocol's shape without writing a byte.

## The suspend-to-idle route — works, and is not safe to run

`deep` resumes in hardware before any code runs, so there is no moment in which to judge a wake.
Suspend-to-idle has one: interrupts are serviced throughout and `s2idle_loop()` exits on
`pm_wakeup_pending()`, not on the interrupt. `0009` uses it, and **the mechanism is proven on this
board**: six chip interrupts serviced while asleep, read over SDIO, classified, with
`Disconnect Complete` refused a wake and an advertising report taking one.

Four obstacles stand between the interrupt and that decision, all traced in `s2idle-feasibility.md`
and all cleared by `0009`:

- the chip interrupt is wake-armed, so `irq_pm_check_wakeup()` takes it and the handler never runs
- `dw_mmc-rockchip` gates both SDIO clocks before the sleep starts
- `suspend_device_irqs()` disables the MMC controller's own interrupt, and completions need it
- `skw_resume_check()` waits 35 s for a resume that is not coming

**It still cannot be used, and why is not yet established.** In real use the box had trouble
entering suspend, trouble leaving it, and reset itself unprompted.

The suspect that did _not_ survive checking is `rockchip_pm_config.c`. It computes
`mem_sleep_current - PM_SUSPEND_MEM` into an unsigned enum, so under suspend-to-idle
`pm_config_prepare()` always takes its out-of-range early return and `pm_config_complete()` puts a
runtime-PM reference nothing took — `Runtime PM usage count underflow!` on every s2idle resume, with
or without this patch. It is cosmetic: the configuration that early return skips is only consumed by
a suspend ATF performs, and s2idle never reaches `suspend_ops->enter()`.

So the instability remains unattributed, and the two liberties `0009` takes — driving another
driver's device through `pm_runtime_force_resume()`/`pm_runtime_force_suspend()`, and incrementing
an interrupt descriptor's `no_suspend_depth` — are still the leading suspects. Clearing them needs a
real s2idle suspend with stock modules, which needs a wake source this board does not have.

`0008` cleared none of the four; it used `disable_irq_wake()`, which only moves the line from the
wake-armed case to the masked one. The two patches are mutually exclusive, and neither ships.

## Still unexplored

- **HDMI CEC can wake the box.** `dw-hdmi-cec.1.auto` reports `power/wakeup = enabled`, and
  `hdmi_cec_key` is `event1`. Untested — nothing was connected — but it is the one non-BLE wake path
  this board appears to have.
- One run with the quirk active ended with **both LEDs off**, a state no hook here produces, so a
  hang rather than a suspend. Never reproduced, cause unknown.

**`adc-keys` cannot wake it** ➖. `drivers/input/keyboard/adc-keys.c` never calls
`device_init_wakeup()`, `evdev` raises no wakeup event of its own, and the node's only key is
`linux,code = <0x57>`, KEY_VOLUMEUP. Polling continues under s2idle so a press is still seen, but
nothing ends the sleep.
