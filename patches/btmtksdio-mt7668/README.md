# btmtksdio-mt7668 — mainline Bluetooth for the MT7668S

Three patches to mainline's `btmtksdio`, built as DKMS against the running kernel. They apply in
order to the `btmtksdio.c` in Linux 6.18.44. All three apply to chip id `0x7668` alone; the MT7663
and MT7921 behave as before. TVBian's kernel applies all three in-tree.

| Patch  | Fixes                                                                   |
| ------ | ----------------------------------------------------------------------- |
| `0001` | `hci0` closes during setup, and LE scans hear nothing                   |
| `0002` | a Wi-Fi firmware core dump logged per packet holds the shared sdio host |
| `0003` | `hci0` stays down when the Wi-Fi driver loads the shared patch first    |

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

The same bitmap leaves octets 25-28 empty, the Core 4.2 LE commands the firmware runs. The core
builds the LE event mask from them, so with no bitmap read it masks LE Advertising Report and LE
Connection Complete: the controller scans, and the host is told of nothing.

    LE Set Event Mask -> Mask: 0x0000000000000650
    btmgmt find -l    -> no dev_found

The patch skips reading the bitmap and supplies those four octets; the rest stay empty, as BR/EDR
was tested with. With it:

    LE Set Event Mask -> Mask: 0x000000000000065f
    btmgmt find -l    -> 60 dev_found in 15 s

## 0002

The combo firmware sends packet type `0x80` down the Bluetooth function for its own debug output,
including a core dump after a Wi-Fi firmware assert: several hundred packets in a few seconds, each
opening with the vendor event `0xfc6f`. btmtksdio logged each as `Invalid bt type 0x80` from
`btmtksdio_txrx_work()`, which holds the sdio host the Wi-Fi function shares, and at a 115200 serial
console that starved the Wi-Fi driver until the box hung. MediaTek's own driver drops the type; the
patch does the same and logs one `firmware core dump` a minute.

## 0003

Whichever driver loads first downloads the patch both functions share. When mt76 does, it loads its
own ram code for about 0.9 s after, and Bluetooth enabled in that window stops answering:

    Bluetooth: hci0: Firmware already downloaded
    Bluetooth: hci0: command 0xfc7a tx timeout
    Bluetooth: hci0: Failed to apply low power setting (-110)

`hciconfig hci0 up` then fails the same way until the part is reset. The patch semaphore cannot gate
it: mt76 releases it before the ram code, and the running firmware no longer answers it. Found
patched, Bluetooth waits 2 s before enabling.

## Build

    firmware/common/fetch-btmtksdio-src.sh <dir>

stages the source with the patches applied, a Makefile and a `dkms.conf`; a board lists it in
`BOARD_DKMS_FETCH`. `btmtk`'s exports are already in the kernel's `Module.symvers`, and DKMS
installs to `updates/`, which wins over the in-tree module.

## What would have to change before submission

- **The quirk is a blunt instrument.** `HCI_QUIRK_BROKEN_LOCAL_COMMANDS` makes the core treat every
  optional command as absent, not just the one this part gets wrong. A targeted quirk is the right
  shape, and needs a core change this repo cannot carry.
- **`0003` waits a fixed time.** Bluetooth has no signal that the Wi-Fi ram code is running; one
  would replace the 2 s with the actual load.

## Ordering

With mt76 the two load in either order: Bluetooth first, mt76 waits out the held patch semaphore;
mt76 first, `0003` waits out its ram code. MediaTek's own Wi-Fi driver cannot follow a `btmtksdio`
that bound first (`Patch status check timeout`), and its `install.sh` blacklists it.
