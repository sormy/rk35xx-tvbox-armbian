# seekwave-swt6621s — driver patches

Fixes for the Wi-Fi/BT driver shared by the H96 Max and H96 Max 3518D, applied in filename order to
the pinned source by `modules/swt6621s.conf`.

- `0002` — uplink latching at 6 Mbit/s until re-association.
  [PR #1](https://github.com/retro98boy/seekwave-swt6621s/pull/1)
- `0003` — driver chatter filling the kernel error log.
  [PR #2](https://github.com/retro98boy/seekwave-swt6621s/pull/2)
- `0005` — the factory chip images advertise the HCI codec reads and then assert on them
  (`BSPASSERT:hci_tl.c-386`), ending controller init. The driver answers `0x100b`, `0x100d` and
  `0x100e` locally with Unknown HCI Command so they never reach the chip. Off by default; both
  boards enable it with `skwbt.skip_codec_reads=1` from `firmware/common/skwbt-options.conf`, since
  both run the factory chip code. Not submitted upstream.
- `0006` — the Bluetooth driver fails to build on 6.11 and later: `platform_driver.remove` returns
  void, and `class_create()` takes no module. Not submitted upstream.
- `0007` — nothing can load the drivers on demand: the SDIO id table is never exported, and the
  Wi-Fi and Bluetooth drivers have no alias for the platform devices they bind. Exports the table
  and adds both aliases, so udev loads all three as the card and its devices appear. Not submitted
  upstream.

Every patch here applies to pinned commit `b1b15016`; after a bump,
`./build.sh kernel kernel/rk35xx.conf` builds the module from them, which is how to check they still
apply.
