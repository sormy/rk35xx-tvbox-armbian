# H96 Max — open items

What is still open on this box under the overlay. Per-feature state is in the README's table,
measured numbers in `h96max-h313/board.md`. Anything not listed here passed.

## 1. Seekwave driver floods dmesg

✅ Fixed, confirmed 2026-08-26. `skw_hex_dump()` takes a `force` flag that skips the `SKW_DUMP`
check, and five per-packet sites passed `true` — so they dumped whatever the log level said. 1659 of
1678 driver lines over two days were `short skb` from `skw_ndo_start_xmit()` while
`/proc/skwifid/log_level` reported `dump log: disable`.

`0003-skw-stop-per-packet-hex-dumps.patch` passes `false` at those five sites. **0 occurrences in 42
min of uptime** after a kernel upgrade and reboot, against ~35/hour before. Settled.

**A second flood remains, in another module.**
`[SKWSDIO INFO] skw_sdio_rx_thread: line:N cp fifo status(N,N) ret=N` — 111 lines in 42 min, INFO
text emitted at err/warn level from `skw_sdio_lite` rather than `swt6621s_wifi`. Same class as the
one 0003 fixed, and the same remedy applies.

## 2. Warm reboot can come up without `wlan0`

The 1 s → 10 s scan-card wait that fixed this lived in the closed `armbian/build#10440` and is not
carried here. Evidence, the disproven device-tree candidates and the restore step:
`todo/rk35xx-sd-uhs-warm-reset.md`.

## 3. SD UHS root cause

Open, and it is what stands between this board and SDR104: `todo/rk35xx-sd-uhs-warm-reset.md`.

The cost is measured rather than nominal — with `sd-uhs-*` stripped the card reads **22.8 MB/s**
sequential (19.7 write, 1913/393 IOPS), about 91% of the high-speed 50 MHz ceiling, so it is
bus-limited. That is what SDR104 would buy back.

## 4. Wi-Fi TX latch

✅ Deployed 2026-08-25, `txba_stale_sec=10` live. 🟡 Not re-tested against the reproducer since —
inducing the latch needs 2.4 GHz plus CPU load on a daily driver. This box logged one `stale TXBA`
recovery before the deploy, so the detection does fire on real hardware.
`0002-skw-renegotiate-silently-dropped-tx-ba.patch` detects a TX BA session the firmware dropped
without `DEL_TX_BA` and renegotiates it. Full write-up: `h96max-h313/wifi-tx-latch.md`.
