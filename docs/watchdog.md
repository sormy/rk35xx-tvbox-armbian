# The SoC watchdog, and why a soft reboot can strand the box

`snps,dw-wdt @ ffac0000`, enabled in `board.dtb` and armed by systemd from PID 1. It is the only
recovery path for a hard hang on a headless box — and the only hang recorder, since its reset
preserves ramoops to `/var/lib/systemd/pstore/` where a cold power cycle loses it.

**It cannot be stopped once armed, and it keeps counting across a soft reboot.** `shutdown + boot`
therefore has to finish inside whatever is left of the window. If it does not, the hardware resets
the box mid-boot, and no amount of waiting recovers it — only a power cycle.

## The timeout is not fixed at 44 s

dw-wdt steps are `2^(16 + TOP) / clk`. ✅ The watchdog clock is **24 MHz** on the R69 —
`tclk_wdt_ns`, bound to `ffac0000.watchdog` in `clk_summary` — which leaves two useful steps:

| TOP    | Timeout    |                  |
| ------ | ---------- | ---------------- |
| 14     | 44.7 s     | what we shipped  |
| **15** | **89.5 s** | hardware maximum |

`RuntimeWatchdogSec=80` in `/usr/lib/systemd/system.conf.d/zz-tvb-watchdog.conf` rounds up to the 89
s step; systemd pings at half the granted value. ✅ Verified on the R69: the journal reports
`Watchdog running with a hardware timeout of 1min 29s`.

**`RebootWatchdogUSec=10min`, systemd's default shutdown window, is unreachable here** — the driver
clamps to 89 s, so systemd believes it has ~7× more protection than the hardware can give.

## What 89 s does and does not buy

Boot is ~16 s on the R69, so doubling the window roughly doubles the margin before the carry-over
bites. It is **not** a guarantee: 89 s is the ceiling, and a slow shutdown still eats the budget.

🟡 **The warning is now seen here; the strand that followed it is not.** It was first recorded on a
sibling RK3518-class box running the Seekwave stack: after heavy `stress-ng --cpu 8 --io 4 --vm 2`,
ramoops caught `watchdog: watchdog0: watchdog did not stop!` immediately before
`reboot: Restarting system`, the next boot was reset at 15.91 s monotonic, and the box stayed dark
for six hours until power was pulled.

On 2026-09-07 the **same line appeared on the H96 Max 3518D**, in `console-ramoops-0` from an
ordinary `systemctl reboot` after a long media session — same position, immediately before
`reboot: Restarting system`. That box came back normally, so the carry-over reset has still not been
reproduced on hardware here. But the precursor is no longer hypothetical on this family, and the
rule below is not theoretical either.

A `console-ramoops-N` file on its own is **not** a crash: it is the console backend, which ramoops
records continuously by design, and it appears after any warm reboot where DRAM survived. A real
panic or oops leaves a `dmesg-ramoops-N`. There has never been one on these boxes.

**Do not soft-reboot one of these boxes unattended.** Anything that can reboot it — a dead-man
timer, `systemctl reboot` inside a script — needs someone who can reach the power.

## Suspend

✅ **It neither counts through sleep nor misfires on wake.** R69, 2026-08-21, armed at 89 s:

```
18:46:16.818  PM: suspend entry (deep)
18:55:02.966  PM: suspend exit          -> 526.1 s asleep, 5.9x the window
```

`boot_id` unchanged across it (`196099eb-…`), `uptime -s` still 2026-08-18 19:54:38, one boot in
`journalctl --list-boots`, and the box was polled from the host throughout — unreachable the whole
time, so it never self-reset and came back. systemd still holds `/dev/watchdog0` afterwards (`wdctl`
reports it busy) at `RuntimeWatchdogUSec=1min 20s`, so resume re-arms rather than silently dropping
protection. 0 failed units after.

The driver is why. `dw_wdt_suspend()` saves `CONTROL` and `TIMEOUT_RANGE`, then
`clk_disable_unprepare()`s both the counter clock and `pclk` — with `tclk_wdt_ns` gated the counter
has nothing to advance on. That gating is load-bearing, because userspace is frozen in suspend and
systemd cannot ping. `dw_wdt_resume()` restores `TIMEOUT_RANGE` first — it carries TOPINIT, so
enabling loads the full window rather than a hardware default — then restores `CONTROL`, then
`dw_wdt_ping()`s, so the counter starts from the top at resume.

**Suspend is therefore safe in a way soft reboot is not.** Sleep costs nothing from the window; a
reboot carries whatever is left of it into the next boot.

### Repeating the test

Sleep **longer than the window** — 2 minutes is the practical minimum, since systemd pings at half
the granted value and the counter holds 49–89 s at suspend entry.

```sh
cat /proc/sys/kernel/random/boot_id     # note it
systemctl suspend
# wait, polling from the host; then wake with the remote and re-read boot_id
```

| What happens                                 | Means                                      |
| -------------------------------------------- | ------------------------------------------ |
| unreachable throughout, same boot_id on wake | counter gated — what the R69 does          |
| comes back on its own at ~89 s               | counter ran; reset fired during sleep      |
| resumes on the press but with a new boot_id  | counter ran; reset landed on the wake path |

**Hands on the box, not remote.** There is no RTC here, so no `rtcwake` and no self-wake: a
correctly-behaving watchdog leaves the box asleep until someone presses the remote. Success strands
it. Don't run it on a box mid-job either — the failure mode is a reset.

🟡 Not repeated on the H96 Max.

## Telling it apart from the `dwmmc` warm-reboot bug

Both look like "soft reboot wedged the box", and they are different faults:

| Symptom                                                         | Cause                             |
| --------------------------------------------------------------- | --------------------------------- |
| initramfs retries, then `ALERT! UUID=… does not exist`, a shell | `dwmmc` `-110` — see `todo/`      |
| box resets partway through boot, no shell, repeats              | watchdog carried over from before |

## Disabling it

`RuntimeWatchdogSec=off` in the same drop-in, then `systemctl daemon-reexec`. The watchdog is then
never armed and cannot carry over, at the cost of losing automatic recovery from a hard hang — the
failure that matters most on a headless box. Keeping it armed and not soft-rebooting unattended is
the better trade.
