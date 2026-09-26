# H96 Max 3518D — device tree

**Grafts booted and running since 2026-09-06.** `firmware/h96max-3518d/board.patch` is the source;
`upstream/build.sh` compiles it to `firmware/h96max-3518d/board.dtb` and its gate reports
`VERIFIED: native tree is content-identical to the patched tree`. The box boots from it and is
reachable over SSH, so the grafts below are ✅ unless marked otherwise.

Factory tree: `stock/h96max-3518d/board.dtb`, carved from the `boot` partition (not from
`/proc/device-tree` — U-Boot edits that one). 4640 lines, round-trips through the patched `dtc`.

## It is four lines away from the H96 Max

Both boxes ship the same vendor tree, `rockchip,rk3518-evb1-ddr4-v10`, same `model` string. Diffing
`stock/h96max-h313/board.dtb` against `stock/h96max-3518d/board.dtb` with phandles normalised gives
**four differences in 4640 lines**:

| Node                     | H96 Max                                       | 3518D                                   | Consequence                                                                                                                                                                                      |
| ------------------------ | --------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sdhci` (eMMC)           | `max-frequency = 100000000`, `mmc-hs200-1_8v` | `max-frequency = 50000000`, no HS200    | the 3518D runs its eMMC at **half the clock and no HS200**                                                                                                                                       |
| `adc-keys` `vol-up-key`  | `linux,code = <0x73>` (`KEY_VOLUMEUP`)        | `<0x57>` (**`KEY_F11`**)                | the hidden button sends a different key despite the same label                                                                                                                                   |
| `pwm@ffa90030` `ir_key6` | 44-entry table, usercode `0xfb04`             | **66-entry** table, same usercode       | superset — adds `0x02`–`0x0b` (`KEY_1`–`KEY_0`) and `0x3e`/`0x3f`. **The bundled remote has no digit keys**, so those entries are not for it: the table covers a family of remotes, not this one |
| `pwm@ffa90030` `ir_key8` | usercode `0xdd22`, its own table              | usercode `0x212`, a copy of `ir_key6`'s | a different alternate remote; not the bundled one                                                                                                                                                |

Nothing else differs. Not the USB nodes, not the LEDs, not the radio, not the display pipeline, not
the pinmux.

**Do not read the IR tables as a description of the shipped remote.** Nine `ir_keyN` tables are
present, the bundled remote has no digits yet `ir_key6` lists them, and no IR receiver is visible on
the PCB at all. These are vendor boilerplate for a range of remotes. Which table — if any — is live
here has to be measured with `evtest`, not inferred.

## What that means for the grafts

`firmware/h96max-h313/board.patch` is 47 changed lines. Every hunk except two lands on a region that is
**byte-identical** in this board's tree, so it should apply essentially verbatim:

| Graft                                                        | Transfers?                                                    |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| GPU → mainline lima `clocks`/`clock-names`/`interrupt-names` | verbatim                                                      |
| uart0 / `fiq-debugger`                                       | **not grafted here** — left stock, console is `ttyFIQ0`       |
| `watchdog` → `okay`                                          | verbatim                                                      |
| IR `remote_support_psci` → `1`                               | **reverted** — no IR receiver here, `pwm@ffa90030` disabled   |
| LEDs → `work-green`/`work-red` renamed `power`/`standby`     | verbatim                                                      |
| `chosen` dropped                                             | verbatim                                                      |
| `compatible` + `model`                                       | **board's own strings** — see below                           |
| `sdmmc` → drop `sd-uhs-*`                                    | **skip** — no SD slot is fitted, so the graft has no consumer |

### IR is disabled, not grafted around

`pwm@ffa90030` is `status = "disabled"` and `remote_support_psci` is back to the factory `0x00`.
Both were the other way round until 2026-09-06, when the receiver was shown to be absent: the
bundled remote drives the H96 Max box over IR, and this board answers none of it.

Disabling the node is what makes the rest removable. The kernel builds `rockchip_pwm_remotectl` in
without the shared-IRQ fix, which is why other boards pass `initcall_blacklist=rk_pwm_driver_init`
and ship a patched DKMS module to own the receiver instead. With no node to bind, neither driver
runs, so this board carries neither — see `board.conf`'s `BOARD_IR_BLACKLIST=""`.

### Reading the patch: `NOT FITTED` marks a correction, not a change

`firmware/h96max-3518d/board.patch` mixes two kinds of hunk, and the comments say which is which. A
comment opening **`NOT FITTED -`** means the factory tree declares hardware this PCB does not have,
and the graft only stops it being claimed — nine hunks, all of them `status = "disabled"`: `tve`,
`spdif` and its sound card, `acodec` and its sound card, `gmac0`, `sfc`, `sdmmc`, and `pwm@ffa90030`
(IR). The USB 3 pair was in this set and has been taken back out, below.

Every other hunk is a change we want for our own reasons and carries its own rationale instead: the
`compatible`/`model` strings, lima's clock names, the watchdog enable, the LED renames, and dropping
`chosen`. The distinction matters when upstreaming — the `NOT FITTED` set describes this board,
while the rest describes our stack.

### USB 3 is NOT grafted out — it was, and it broke suspend ❌

USB 3 is genuinely not wired: a SuperSpeed device plugged directly into the USB-C socket still
trains at 480M, and the vendor documentation claims no USB 3. So `xhci` registers a 5 Gbps root hub
nothing can ever enumerate on, and between 2026-09-05 and 2026-09-06 we grafted it out —
`maximum-speed = "high-speed"`, `combphy_pu` dropped from dwc3's `phys`, `combphy@ffdc0000`
`disabled`.

**Reverted 2026-09-06: it broke suspend.** With the phy gone, xhci's SuperSpeed half is still
present (the root hub comes from the controller's own capability register, which no DT property
retracts) but unclocked, so it never halts:

```
xhci-hcd xhci-hcd.4.auto: WARN: xHC CMD_RUN timeout
xhci-hcd xhci-hcd.4.auto: PM: dpm_run_callback(): platform_pm_suspend returns -110
PM: Some devices failed to suspend, or early wake event detected
```

Every suspend aborted, and an abort is indistinguishable from an instant wake unless you check
`last_failed_dev`. The R69 and H96 Max H313 keep `combphy` `okay` and suspend fine; this board was
the only one that disabled it and the only one that could not suspend.

The nodes now stay as the factory left them, with the reasoning kept as comments. **A phantom 5 Gbps
root hub is the cheaper problem**: what the graft bought was one fewer PHY probing, about a second
of boot time and a tidier `lsusb -t`; what it cost was suspend on the only board with no other way
to be woken.

### `esmart_lb_mode` — the one-byte fix that makes 4K work ✅

The factory tree sets `esmart_lb_mode = [03]` on the VOP node. That is
`VOP3_ESMART_2K_2K_2K_2K_MODE`: **every Esmart window gets a 2K line buffer**. The primary plane for
vp0 is `Esmart0-win0`, so a 3840-wide mode fetches only ~2048 pixels per line and the rest of every
line is whatever was in the buffer — a filled right-hand portion of the screen.

Grafted to `[02]` = `VOP3_ESMART_4K_2K_2K_MODE`, which gives **Esmart0** a 4K line buffer. Verified
2026-09-07 on a 4K LG TV: boots natively at `3840x2160p60`, console `480x135` (= 3840 px), full
screen correct.

The value is read straight from the DT — `of_property_read_u8(dev->of_node, "esmart_lb_mode", …)` in
`rockchip_drm_vop2.c` — so there is no kernel command line or module parameter for it, and no safe
runtime override (the VOP cannot be unbound while it drives the console). It needs a DTB and a
reboot.

**What `[02]` costs.** `vop3_ignore_plane()` drops a window outright under some modes and
`vop3_esmart_linebuffer_size()` halves it under others. Per-window width on this SoC
(`max_output.width` = 4096):

| `esmart_lb_mode`   | Esmart0  | Esmart1     | Esmart2 | Esmart3 |
| ------------------ | -------- | ----------- | ------- | ------- |
| `[00]` 8K          | 4096     | dropped     | dropped | dropped |
| `[01]` 4K_4K       | 4096     | dropped     | 4096    | dropped |
| **`[02]` ours**    | **4096** | **dropped** | 2048    | 2048    |
| `[03]` factory     | 2048     | 2048        | 2048    | 2048    |
| `[04]` 4K_4K_4K    | 4096     | 4096        | 4096    | dropped |
| `[05]` 4K_4K_2K_2K | 4096     | 4096        | 2048    | 2048    |

**Cluster windows are exempt** — that function returns the full width for them under every mode, so
`Cluster0-win0` stays a 4K-capable overlay whatever this property says.

🟡 **`[04]` and `[05]` are probably not this SoC's.** The first four modes each sum to 8K of line
buffer; those two sum to 12K, and `rk3576` — the only VOP3 carrying an `esmart_lb_mode_map` — is the
likelier owner. Read off the arithmetic, not the TRM.

`[01]` is the only alternative leaving two 4K planes on vp0, Esmart0 and Esmart2. It costs Esmart3,
which is vp1's primary — the TVE output this board does not have.

**Refresh rate is a red herring.** 4K30 (297 MHz, half the pixel clock of 4K60) failed in exactly
the same way. The limit is line width, not bandwidth or TMDS rate — which is what rules out the HDMI
PHY, the DMC and every clock as suspects.

**Confirmed on two different displays.** A 4K LG TV lost roughly half the screen at 3840 wide; a
2256x1504 monitor lost about 30% of its right-hand side. Both render correctly with `[02]`. The
fault is not "4K is broken" — it is **any mode wider than the line buffer**, which is why 1080p
always looked fine and why the visible damage scales with width.

**All three boards ship the same factory `03`**, so all three carry this graft. The R69 and H96 Max
have it in the tree but have not been reflashed and retested — the same monitor showed the fault on
them before the fix.

### The compatible is not cosmetic

The H96 Max uses:

```
compatible = "h96max-zx,rk3518-tvbox", "rockchip,rk3518-evb1-ddr4-v10", "rockchip,rk3518", "rockchip,rk3528a";
```

Both ends of that chain do work, and both matter here:

- **Board name first** — the Seekwave driver builds firmware filenames from it, looking for
  `<name>.<board-compatible>.<ext>` before the generic name. This board's Seekwave NV and RF
  calibration blobs differ from the H96 Max's, so the compatible is what keeps them apart. It has to
  be this board's own string, `h96max-3518d,rk3518-tvbox`.
- **`rockchip,rk3528a` last** — rkmpp has no `rk3518` entry and cannot find the VPU without it.
  **This board needs the append more than the R69 does.** `docs/r69/board.md` notes MPP works there
  because "the factory tree already says `rockchip,rk3528a`" — but that is the _runtime_ tree, which
  the vendor U-Boot rewrites. The disk tree here says `rockchip,rk3518`, and our U-Boot does no such
  rewrite, so without the append nothing downstream can name the SoC.

## Open graft candidate — the eMMC clock

The sibling board's factory tree asks for 100 MHz + HS200 on the same SoC and the same `sdhci` node;
this one asks for 50 MHz and no HS200. The part is capable either way — `DEVICE_TYPE 0x57`
advertises HS400, HS200 and DDR52, and the vendor U-Boot reads at HS400 200 MHz before Linux ever
starts.

So the cap is a choice in this board's tree, and raising it to match the H96 Max is a one-property
experiment with a sibling as prior evidence.

**Do not treat that as free.** `docs/r69/board.md` records HS400ES reading ~290 MB/s on the R69 and
then corrupting sustained writes, which is why that board is deliberately pinned at HS200. Measure
with `fio` and verify written data before keeping any raise, and change one property at a time.

Order of business: get the box booting on the factory 50 MHz value first, and only then treat the
clock as a separate, measured experiment.

## Graft candidate — disable what is not on the board

Inspection on 2026-09-05 established that most of the I/O the EVB tree declares is absent here: no
Ethernet, no microSD, no composite, no SPDIF, no analog audio, no visible IR receiver. See
`h96max-3518d/board.md` for the per-node evidence.

The standing rule is to leave factory nodes alone unless a graft has a functional consumer. One of
these does:

- **`gmac0` → `disabled`.** The PHY does not answer, so every boot spends time on
  `phy_poll_reset failed: -110` and then logs `Cannot attach to PHY (error: -110)`. Disabling it
  removes a boot delay and two spurious errors. That is a consumer.

The rest (`sdmmc`, `tve`, `spdif`, `acodec`, `es7243e`, `sfc`) cost nothing at runtime — an enabled
node whose hardware is missing simply never probes, or probes a controller with nothing attached.
Leave them, and keep the diff to the factory tree small.

⚠️ **The board may carry unpopulated footprints.** A node matching nothing visible does not prove
the SoC block is unusable — only that this unit has nothing wired to it. Disabling on the strength
of "I cannot see it" would be wrong for anything but `gmac0`, where the PHY was actively probed and
did not reply.

## Console: this board keeps the vendor's

The R69 and H96 Max enable uart0 as `ttyS0` and disable `fiq-debugger`. **This board does not.** The
graft was justified by reading `could not install nmi irq handler` as breakage, but stock Android
logs the same three `-ENXIO` lines on this hardware and its `ttyFIQ0` console works — the vendor
sets `rockchip,irq-mode-enable = <1>` because there is no FIQ here. Nothing is lost by leaving it:
the debugger half never initialises either way, so `ttyFIQ0` is a plain tty over uart0.

So the tree is stock for both nodes and `board.conf` sets
`BOARD_SERIALCON="earlycon=uart8250,mmio32,0xff9f0000 console=ttyFIQ0"`; the baud comes from the
node's `rockchip,baudrate`. systemd's getty-generator reads `/proc/consoles`, so the login prompt
follows with no unit of ours.

🟡 **Untested** — the box has not booted since. If `ttyFIQ0` does not come up, the other two boards
show the fallback: graft uart0 to `okay`, `fiq-debugger` to `disabled`, drop `BOARD_SERIALCON`.
