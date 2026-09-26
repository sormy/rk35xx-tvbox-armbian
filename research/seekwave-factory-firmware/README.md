# Running the factory Seekwave chip images

**Adopted 2026-09-13**, shipped as `patches/seekwave-swt6621s/0005`. This holds why, and the
measurements taken on the way — including the ones that argued against it.

## Why the swap happened

The factory images advertise the HCI codec-read commands in their own supported-commands bitmap and
then assert when one is sent — `BSPASSERT:hci_tl.c-386`, delivered to the host as
`HCI_EV_HARDWARE_ERROR`, which ends controller init before anything is usable. Traced on an H96 Max
3518D in August 2026: roughly eighty init commands answered perfectly, then Read Local Supported
Codec Capabilities (`0x100e`) kills it. `docs/h96max-h313/worklog.md` has the original trace.

The core cannot know. It gates those reads on the bitmap the controller itself supplied, so a
firmware that lies is indistinguishable from one that works.

## The patch

`0005` answers `0x100b`, `0x100d` and `0x100e` in the driver with Unknown HCI Command — what the
core already expects from a controller lacking them — so they never reach the chip. Gated on
`skwbt.skip_codec_reads=1`, default off.

`HCI_QUIRK_BROKEN_LOCAL_COMMANDS` would also avoid them, by skipping Read Local Supported Commands
entirely, but that zeroes the whole bitmap and takes dozens of unrelated features down with it —
including the event-mask-page-2 and disconnect paths.

## Proven on hardware

2026-09-12, H96 Max 3518D, factory images in `/lib/firmware` with the quirk set:

```
[SKWBT_INFO] answering codec read 0x100d locally
hci0: UP RUNNING     chip version 0x5302
```

Wi-Fi unaffected throughout. Without the quirk the same images give `hci0: DOWN` and
`Bluetooth: hci0: hardware error 0x00`.

## Why it stayed parked for a month

- **It does not fix BT wake**, which is what it was tried for. Suspend measured 2.16 s against the
  K3B baseline of 2.00 s — the same reconnect hunt. See `research/seekwave-bt-wake`.
- **The factory images support fewer vendor extensions**, not more: `LE_Get_Vendor_Capabilities`
  returns Unknown HCI Command, where K3B answers (reporting `filtering_support = 0`).
- **No soak**, at the time. Answered since on both boards: the 3518D has run the factory images
  continuously with Wi-Fi as its only link and carried the sleep/wake validation, and the H96 Max
  measured 64.2/68.8/70.1 Mbit/s uplink against a 63.8 Mbit/s K3B baseline, with no TX latch.

## Reverting

Two files in `firmware/common/seekwave-fw/`; git history holds the K3B build. `0005` can stay — it
is inert against K3B, which does not assert on the codec reads.
