# H96 Max H313 — open items

What is still open on this box under the overlay. Per-feature state is in the README's table,
measured numbers in `h96max-h313/board.md`. Anything not listed here passed.

## 1. Seekwave driver floods dmesg

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
