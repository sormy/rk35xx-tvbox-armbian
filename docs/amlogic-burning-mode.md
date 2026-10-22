# Amlogic burning mode — entry, backup, restore

U-Boot's USB burning gadget, Amlogic's counterpart to Rockchip's Maskrom: the whole eMMC and any
U-Boot command over the OTG cable, the case closed. `amlcmd` drives it, from a Mac or a Linux host;
`./build-amltools.sh` builds it into `tools/aml/`. Every command here runs on the host.

**The cable:** a USB-A male-to-male into the box's OTG port, with a USB-C→USB-A female adapter on
any end that is USB-C. It powers the box, so the PSU stays out.

## Entering

Start `amlcmd connect` **before** triggering the box: it abandons burning mode unless identified
within 750 ms, and once identified the link holds with no host process attached.

| From              | Do this                                                      |
| ----------------- | ------------------------------------------------------------ |
| a stock box, off  | apply power; its `try_auto_burn` opens the gadget for 700 ms |
| a powered-off box | hold the button, apply power                                 |
| an Android shell  | `su -c 'reboot update'`                                      |
| a U-Boot prompt   | `update`                                                     |

```sh
amlcmd connect               # start first, then trigger the box
amlcmd status                # which gadget answered
amlcmd --help                # every verb
```

## Backup and restore

```sh
amlcmd backup emmc-stock.img
amlcmd restore emmc-stock.img
amlcmd backup part.img 0x2ae000 0x8000    # start sector, count
amlcmd read store boot 0x1000 boot.bin    # a named partition, through the store layer
```

- 10.5 MiB/s: a 15 GB eMMC takes about 25 minutes. The cost is the vendor U-Boot's per-chunk round
  trip, not the host.
- Sectors are absolute eMMC sectors, the offsets in a board's `partition-map.txt`.
- Both lift the key guard with `store disprotect key`, or a pass stops at the key window. A restore
  therefore writes the image's keys back: right for that box's own backup, wrong for any other.
- The size comes from `amlmmc size wholeDev`, the boot device; another device takes an explicit
  count.

## The mask ROM

| Gadget         | `identify`          | Reaches                      |
| -------------- | ------------------- | ---------------------------- |
| burning gadget | ROM 0.7, Stage 0.16 | eMMC, and any U-Boot command |
| mask ROM       | ROM 2.4, Stage 0.0  | SRAM and code, no storage    |

The button cannot reach it — U-Boot samples the button — but one command does:

```sh
amlcmd set_usb_boot 2
amlcmd reset                 # BL2 then prints `Skip usb!` and stops
amlcmd rom read 0xd9000000 0x1000 sram.bin
```

- Only `rom` works there; any other command kills the link.
- There is no way back without cutting power. Enter it only to unbrick.
- A write to DRAM drops the box off the bus, so the ROM runs code but cannot move an image.
- The addresses are GX-family; `pyamlboot`'s board directories have the others.
- Not implemented: bulk memory (`0x11` `0x12`), the AMLC handover G12 uses, ADNL. `pyamlboot` has
  them.

## Recovering

```sh
amlcmd drain                 # a transfer killed mid-way left a chunk queued
```

A gadget that stays enumerated but times out on identify takes a power cycle; no USB-level reset
clears it.
