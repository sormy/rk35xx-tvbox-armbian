# Can suspend-to-idle filter Bluetooth wakes on this board

Traced against the kernel this board runs (6.1.115, `~/projects/armbian-rk35xx/kernel`) and the
Seekwave driver as shipped here. Written before writing any code, because the first attempt was
built on a wrong root cause and burned a night proving the wrong thing.

**Verdict: possible, module-only, with one invasive step.** Five obstacles stand between the chip
raising host-wake and the driver deciding whether it deserves a wake. Three are ours and cheap. One
needs an exported call used in an unusual place. One has no clean answer and is the reason to stop
and think before committing.

## Why s2idle is the only state where this can work

`suspend_enter()` — `kernel/power/suspend.c`:

```c
	error = dpm_suspend_noirq(PMSG_SUSPEND);
	...
	if (state == PM_SUSPEND_TO_IDLE) {
		s2idle_loop();
		goto Platform_wake;
	}
	error = pm_sleep_disable_secondary_cpus();
	arch_suspend_disable_irqs();
	...
	error = suspend_ops->enter(state);
```

In `deep` the last thing that runs is `suspend_ops->enter()`, and the SoC comes back in hardware —
there is no instruction between the wake and the resume, so there is nothing to decide with. In
`s2idle` the CPUs merely idle; an interrupt wakes one, the handler runs, kernel threads run, timers
run, and the loop exits only when `pm_wakeup_pending()` becomes true. That is the decision point.

## Wall 1 — the chip's host-wake interrupt never reaches the handler

`suspend_device_irq()` — `kernel/irq/pm.c` — takes one of three paths:

- `desc->no_suspend_depth` non-zero: returns `false` immediately. Line stays enabled and unarmed.
  The handler runs during the sleep and firing it does **not** wake the system.
- `irqd_is_wakeup_set()`, i.e. `enable_irq_wake()` was called: sets `IRQD_WAKEUP_ARMED`. When the
  IRQ then fires, `irq_pm_check_wakeup()` disables it and calls `pm_system_irq_wakeup()` — **the
  handler never runs.**
- neither: `desc->istate |= IRQS_SUSPENDED; __disable_irq(desc);` — the handler never runs and
  nothing wakes.

`skw_sdio_host_irq_init()` calls `enable_irq_wake(skw_sdio->irq_num)`, so the driver is in the
second case: unfiltered wake, by construction.

**This is what the first s2idle attempt got wrong.** `no_irq_wake` called `disable_irq_wake()`,
which moves the line from the second case to the third — masked, no handler, no wake. The box slept
through everything and nothing could wake it, and that was read as `skw_resume_check()` blocking the
RX thread. `skw_resume_check()` is real but it is wall 3; the RX thread was never reached at all.

The correct mechanism is `IRQF_NO_SUSPEND` at `request_irq()` time.
`Documentation/power/suspend-and-interrupts.rst` is explicit that it and `enable_irq_wake()` must
never both be used on one IRQ, so this is a mode, not an addition: with it the board cannot wake on
Bluetooth from `deep` at all.

## Wall 2 — the MMC controller's clocks are off

Classification needs the packet, the packet needs a CMD52/CMD53, and SDIO1 is `dw_mmc`:

```
compatible = "rockchip,rk3528-dw-mshc", "rockchip,rk3288-dw-mshc";
```

`dw_mci_rockchip_dev_pm_ops` is
`SET_SYSTEM_SLEEP_PM_OPS(pm_runtime_force_suspend, pm_runtime_force_resume)`, and
`dw_mci_runtime_suspend()` does `clk_disable_unprepare()` on `ciu_clk` and — because the node is
`non-removable` — on `biu_clk` too. Both are plain gates in `clk-rk3528.c` with flag `0`, not
`CLK_IS_CRITICAL`, so they genuinely stop. That runs in `dpm_suspend()`, long before
`s2idle_loop()`.

A runtime-PM reference does not help: `pm_runtime_force_suspend()` calls the callback whatever the
usage count is. The node sets both `no-sd` and `no-mmc`, so `dw_mci_rockchip_probe()` leaves
`use_rpm = false` and never calls `pm_runtime_enable()` — which is why the clocks are simply always
on in normal operation, and why `mmc_claim_host()`'s `pm_runtime_get_sync(mmc_dev(host))` is a no-op
here.

**Answer:** `pm_runtime_force_resume(mmc_dev(host))` before the read and
`pm_runtime_force_suspend(mmc_dev(host))` after it. Both are `EXPORT_SYMBOL_GPL`. Balanced, provided
the driver **always** re-suspends before leaving the section, including on the path where it decides
to wake the system — `pm_runtime_force_resume()` ends in `pm_runtime_enable()`, so leaving the
device resumed makes the PM core's own resume call unbalance `disable_depth` and enable runtime PM
on a device whose driver opted out of it.

## Wall 3 — the RX thread waits for a resume that is not coming

```c
void skw_resume_check(void)
{
	while ((!atomic_read(&skw_sdio->resume_flag)) && (timeout++ < 20000))
		usleep_range(1500, 2000);
}
```

`resume_flag` is cleared in `skw_sdio_suspend()` and set only in `skw_sdio_resume()`, so every
transfer helper and the RX thread itself stall for ~35 s and then proceed anyway. Ours to fix: skip
the wait while the driver knows it is deliberately running inside s2idle.

## Wall 4 — the MMC controller's own interrupt is disabled

`dw_mci_request()` completes through `dw_mci_interrupt`, and `dw_mmc-pltfm.c` sets
`host->irq_flags = 0`, so that IRQ is neither `IRQF_NO_SUSPEND` nor a wake source: it lands in the
third case above and is masked for the whole sleep. Without it a CMD52 does not complete.

Three module-level ways out, two of which fail:

- Attach a second action with `IRQF_SHARED | IRQF_NO_SUSPEND`. Fails — the original request is not
  `IRQF_SHARED`, so `request_irq()` returns `-EBUSY`.
- `enable_irq()` on it during the sleep. Fails — `__enable_irq()` has an explicit
  `if (desc->istate & IRQS_SUSPENDED) goto err_out;`, which warns and does nothing.
- Increment the descriptor's `no_suspend_depth` before suspend and decrement it after. Works, but
  not the obvious way: `irq_to_desc()` is exported only under `CONFIG_KVM_BOOK3S_64_HV_MODULE`, so a
  module linking against it fails `modpost` with `"irq_to_desc" undefined`. `irq_get_irq_data()` is
  `EXPORT_SYMBOL_GPL` and `irq_data_to_desc()` is a header inline, which reaches the same
  descriptor. `suspend_device_irq()` tests that field first, and `resume_irq()` then leaves the line
  alone because `IRQS_SUSPENDED` was never set, so it stays balanced.

The third is reaching into another subsystem's private bookkeeping, around an export the kernel
deliberately restricts, and is the part of this design that should give anyone pause. It also opens
a hazard: the line becomes live from the moment `dpm_suspend_noirq()` runs, while `dw_mci`'s clocks
were already gated back in `dpm_suspend()`. Any interrupt in that window enters `dw_mci_interrupt`
and does `mci_readl()` against a clock-gated peripheral. Closing it costs one more step —
`disable_irq()` alongside the bump, and `enable_irq()` only after the clocks are back. That pairing
is legal because the line is never `IRQS_SUSPENDED`.

## Not walls

Checked because each would have been fatal:

- **The RX thread is not frozen.** No `set_freezable()` anywhere in the Seekwave tree, so it is not
  a freezable kthread and runs normally during s2idle.
- **The MMC core does not block transfers on a suspended card.** `mmc_card_suspended()` is tested
  only in `sdio_irq.c` and in the mmc/sd suspend bookkeeping, never in the request path.
- **Timers run.** `timekeeping_suspend()` is a syscore callback and syscore is `deep`-only, so
  `dw_mci_cto_timer` still fires. A transfer that goes wrong times out instead of hanging.
- **The card keeps power.** `skw_sdio_suspend()` sets `MMC_PM_KEEP_POWER` and `mmc_sdio_suspend()`
  honours it.
- **The in-band SDIO IRQ is irrelevant.** This board runs `SKW_SDIO_EXTERNAL_IRQ`; the in-band IRQ
  was released at boot.

## What the handler and the thread actually do

The GPIO handler cannot classify — it only knows the chip has something. `host_gpio_in_routine()`
already raises `gpio_out` and sets `resume_com` from interrupt context, telling the chip the host is
up, and `skw_sdio_rx_up()` kicks the thread. The thread does the CMD52 on `SKW_SDIO_CP2AP_FIFO_IND`,
reads the packet, and only then can `skwbt_wake_worthy()` in `skw_btdriver.c` say whether it was
input:

- `HCI_ACLDATA_PKT` — a HID report from a connected remote. Wake.
- LE Meta with subevent `0x02` (Advertising Report) or `0x0d` (Extended Advertising Report) — a
  keypress after the link dropped. Wake.
- Anything else — payload-timeout expiry, disconnect, completed packets. Deliver to the stack, do
  not wake.

Nothing is masked, so the host's connection state stays consistent. That is the difference from the
`Disconnect Complete` mask that produced a 19.6 h unwakeable box.

## Order of operations

```
skw_sdio_suspend, s2idle only:
    irq_to_desc(mmc_irq)->no_suspend_depth++
    disable_irq(mmc_irq)
    s2idle_active = 1

GPIO IRQ during the sleep (IRQF_NO_SUSPEND, so the handler runs and nothing wakes):
    kick the RX thread

RX thread:
    skw_resume_check() returns at once while s2idle_active
    pm_runtime_force_resume(mmc_dev)   -> clocks back
    enable_irq(mmc_irq)                -> completions work
    read and classify
    disable_irq(mmc_irq)
    pm_runtime_force_suspend(mmc_dev)  -> clocks off, PM state as the core left it
    pm_system_wakeup() only if the packet was input

skw_sdio_resume:
    s2idle_active = 0
    enable_irq(mmc_irq)
    irq_to_desc(mmc_irq)->no_suspend_depth--
```

## Failure modes to watch for on first test

- Box sleeps and nothing wakes it: wall 1 not actually cleared — check the handler is being entered
  at all before blaming anything downstream. This is the failure the first attempt produced.
- Box hangs entering or leaving suspend: an MMC interrupt taken with clocks gated. The
  `disable_irq()` pairing above is what prevents it.
- `Unbalanced pm_runtime_enable!` in the log after resume: a path returned without re-suspending the
  MMC device.
- Wi-Fi dead after resume: the same transport carries Wi-Fi, and `dw_mci_runtime_resume()` resets
  the controller. Check `skw_sdio_lite` before concluding anything about Bluetooth.

## Cost

Roughly 150 lines across three files, touching the interrupt core's bookkeeping, the runtime PM of a
device owned by another driver, and the shared SDIO transport that Wi-Fi also rides on — to stop one
spurious wake an hour on a stick with no other input path. It works or it does not; what it cannot
be is half-trusted.

## Outcome

Built, run, and reverted the same day. The mechanism worked exactly as traced — the handler runs
under `IRQF_NO_SUSPEND`, `pm_runtime_force_resume()` returns 0 so the SDIO clocks come back, the
unmasked controller interrupt completes the transfers, and the classifier judges each packet.

The predictions in "Failure modes to watch for" were wrong about which one would bite. It was not a
box that never wakes, nor a hang with clocks gated. It was instability: trouble entering suspend,
trouble leaving it, an unprompted reset, and
`rockchip-pm rockchip-suspend: Runtime PM usage count underflow!` on every s2idle resume and never
in `deep`.

The balance argument above — that `force_resume`/`force_suspend` is symmetric provided the driver
always re-suspends, and that `no_suspend_depth` stays balanced because `IRQS_SUSPENDED` is never set
— reads correctly against the source and is contradicted by the board. Whatever is unbalanced is not
accounted for by that reasoning, and finding it is where anyone resuming this starts.
