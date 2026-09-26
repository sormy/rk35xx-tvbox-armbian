# btmtksdio-mt7668 — mainline Bluetooth for the MT7668S

Two patches to mainline's `btmtksdio`, built out of tree against the running kernel. They apply in
order to the `btmtksdio.c` in Linux 6.18.44. Both apply to chip id `0x7668` alone; the MT7663 and
MT7921 behave as before.

| Patch  | Fixes                                                                   |
| ------ | ----------------------------------------------------------------------- |
| `0001` | `hci0` closes again during setup                                        |
| `0002` | a Wi-Fi firmware core dump logged per packet holds the shared sdio host |

## 0001

Without it `hci0` registers with a real address and then closes again:

    Bluetooth: hci0: Device setup in 3203075 usecs
    Bluetooth: hci0: Opcode 0x2031 failed: -56
    btmgmt info -> Index list with 0 items

`0x2031` is LE Set Default PHY and `-56` is HCI status 0x01, Unknown HCI Command. The part claims
the command in its supported-command bitmap and its firmware rejects it, and the call is an
`HCI_INIT` entry in `hci_init4`, so `hci_init_sync()` aborts and the controller never reaches the
management layer. With the patch:

    btmgmt info -> Index list with 1 item, powered ssp br/edr le secure-conn
    btmgmt find -> dev_found E8:FB:1C:66:E9:84 type BR/EDR rssi -79

## 0002

The combo firmware sends packet type `0x80` down the Bluetooth function for its own debug output,
including a core dump after a Wi-Fi firmware assert: several hundred packets in a few seconds, each
opening with the vendor event `0xfc6f`. btmtksdio logged each as `Invalid bt type 0x80` from
`btmtksdio_txrx_work()`, which holds the sdio host the Wi-Fi function shares, and at a 115200 serial
console that starved the Wi-Fi driver until the box hung. MediaTek's own driver drops the type; the
patch does the same and logs one `firmware core dump` a minute.

## Build

    curl -O https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/bluetooth/btmtksdio.c?h=v<ver>

`btmtk.h` and `hci_uart.h` come from the same directory, `obj-m += btmtksdio.o` is the whole
Makefile, and `btmtk`'s exports are already in the kernel's `Module.symvers`. Install to
`/lib/modules/<ver>/updates/` so it wins over the in-tree module.

## What would have to change before submission

- **The quirk is a blunt instrument.** `HCI_QUIRK_BROKEN_LOCAL_COMMANDS` makes the core treat every
  optional command as absent, not just the one this part gets wrong. A targeted quirk is the right
  shape, and needs a core change this repo cannot carry.

## Ordering

`btmtksdio` must not probe before the Wi-Fi driver. Function 2 and function 1 share the part's WMT
path, and a `btmtksdio` that binds first leaves the Wi-Fi side unable to download firmware
(`Patch status check timeout`). MediaTek's own `install.sh` blacklists it for the same reason. With
Wi-Fi up first, BT setup drops from 3.2 s to 43 ms because the shared ROM patch is already loaded.
