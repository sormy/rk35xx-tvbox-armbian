# `dwmmc` fails its first init after a warm reset

Shipped state: `sd-uhs-sdr12/25/50/104` **stripped** from `mmc@ffc30000` on the H96 Max. Mitigates
the SD half only, and costs SDR104 on the SD slot — 148.5 MHz down to high-speed 50 MHz. Getting
that back is what this TODO buys.

❌ **The Wi-Fi half is unmitigated.** The 1 s → 10 s scan-card wait that fixed it was a patch
against the Armbian build tree in the closed `armbian/build#10440`. The overlay stages the pinned
upstream driver unmodified: `skw_sdio_scan_card()` in
`drivers/seekwaveplatform_lite/sdio/skw_sdio_main.c` still calls
`wait_for_completion_timeout(&skw_sdio->scan_done, msecs_to_jiffies(1000))` at commit `b1b15016`, so
a warm reboot can still come up without `wlan0`.

Symptom and the five disproven device-tree candidates are in `h96max-h313/board.md` and
`h96max-h313/dtb.md`. This file is the open question only.

## What is actually established

From `verbosity=7` captured through ramoops on a failing warm reboot (2026-08-15):

| Controller            | Driver           | First init after warm reset                      |
| --------------------- | ---------------- | ------------------------------------------------ |
| `mmc@ffc20000` SDIO   | `dwmmc_rockchip` | `-110`, then recovers → SDR104 SDIO card         |
| `mmc@ffc30000` SD     | `dwmmc_rockchip` | `-110`, retries at 15.19 / 15.81 / 16.41 — never |
| `sdhci@ffbf0000` eMMC | `rk3528-dwcmshc` | clean, HS200                                     |

Three facts constrain any theory:

1. **It is per driver, not per card.** Both `dwmmc` controllers stumble; the `sdhci` eMMC never has.
2. **The card is awake and answering.** U-Boot reads `boot.scr`, the kernel, the DTB and `uInitrd`
   off that same SD immediately before, so whatever state the card is in, it is not wedged — only
   the kernel's re-enumeration fails. This is what rules out "the card latched in 1.8 V UHS mode
   across the reset", the obvious first theory.
3. **A cold power cycle always recovers it**, a warm reset intermittently does not.

**Which command returns `-110` is still unknown**, and it decides everything — CMD0/CMD8 means the
bus never came up, ACMD41/CMD5 means it did and the card refused. Nothing captured so far names it.

## What is _not_ the cause

**The `static bool inherit` bug in `dw_mci_v2_execute_tuning()`** — a per-host decision kept in a
function-scope static, so on a SoC with two v2-tuning controllers only the first to probe adopts its
firmware sample phase. Real, and a fix exists as
`patch/kernel/rk35xx-vendor-6.1/mmc-dw-mmc-rockchip-per-host-inherit.patch` in the Armbian build
checkout — **untracked there, on branch `r69-xr821`**, so a `git clean` loses it. Never tested on
hardware, and it cannot reach an overlay box in any case: Armbian's `patch/` and `userpatches/`
trees only apply when you build the kernel, and we take ours from `apt`.

It cannot explain the H96 Max: only `mmc@ffc30000` sets `rockchip,use-v2-tuning` there, and the SDIO
`mmc@ffc20000` `-110`s too without it.

**Nor can it fire on the R69**, though that board does set `use-v2-tuning` on two enabled
controllers: `mmc@ffc30000` has no UHS or HS200 modes left after the strip, and plain high speed
never calls `execute_tuning`. Restoring them there is not an option either — that SD has no
`vqmmc-supply`, so no 1.8 V switch to run UHS with.

Restoring UHS **here** is on the table, since this board has a real `vccio_sd` switch, but it still
would not reach that bug: this SDIO controller does not declare `use-v2-tuning`, so it stays on the
non-v2 path whatever the SD does. The two subjects are unrelated.

## Next experiments, cheapest first

1. **Name the failing command.** `dw_mmc.dyndbg=+p mmc_core.dyndbg=+p`, reboot in a loop until it
   fails, read the previous boot from `/var/lib/systemd/pstore/`. ramoops survives a power cycle on
   this box, so nothing is lost when it needs one.
2. **Dump the controller and CRU state at probe** — `CTRL`, `CLKDIV`, `CLKENA`, `UHS_REG`, plus the
   `ciu-sample`/`ciu-drive` phase registers — and diff cold vs warm. A warm reset that leaves the
   CRU's mmc phase or divider registers loaded is a one-boot test.
3. **Check the IP is actually reset.** Both nodes carry `resets`/`reset-names = "reset"`; confirm
   `dw_mci_probe()` asserts it rather than skipping, and force it if not.
4. **Bisect the mode, not the property.** Restore `sd-uhs-sdr25` alone, then `sdr50`, then `sdr104`.
   If only SDR104 fails, it is tuning; if any 1.8 V mode fails, it is signalling.
5. **Does stock Android reboot cleanly?** Same silicon, same vendor driver — if it does, diff its
   `mmc` setup against ours.
6. **Measure what the strip costs.** `fio` on the SD with and without the UHS properties; the ~70
   MB/s SDR104 figure quoted in `board.md` is nominal, not measured on this board.
7. **Carry the scan-card wait in the overlay.** `fetch-seekwave-src.sh` has no patch step; the IR
   driver next door shows the pattern (`patch -p1` after the fetch). Restores a fix already proven
   over 15 warm reboots.

## Done means

Either the `-110` is root-caused and `sd-uhs-sdr12/25/50/104` goes back into
`firmware/h96max-h313/board.dts` with warm reboots still clean over 10 iterations — or the cause is
found to be unfixable in the tree, and this file says so with the evidence.
