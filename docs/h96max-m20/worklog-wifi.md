# H96 Max M20 — Wi-Fi and Bluetooth worklog

Dated history, wrong turns included. Board id `h96max-m20`, provisional — the box's own strings say
`S905LTS` on platform `p291`. PCB silkscreen `905_DG_ZX01_V01 2025/09/03`.

## 2026-09-17 — the vendor pin numbers are not mainline's, and the firmware is not an MT7663's

### GPIOX_6, not GPIOX_9

The factory tree names the Wi-Fi power pin `power_on_pin = <&gpio 0x58 0>`, and the Android log
resolves it: `power_on_pin=486` against a periphs bank based at 398, so periphs offset 88.
Translated straight into our tree as `<&gpio 88 1>`, which is **GPIOX_9** in mainline and nothing on
this board.

The two pinctrl drivers do not number alike. The vendor's GXLX bank gives GPIOH 13 pins where
mainline's meson-gxl gives it 10, so everything from BOOT upward sits three higher in the vendor's
numbering. `/sys/kernel/debug/pinctrl/pinctrl@4b0-pinctrl-meson/pins` on the box settles it: pin 85
is GPIOX_6, pin 88 is GPIOX_9.

| Function            | Factory property     | Vendor pin | Mainline |
| ------------------- | -------------------- | ---------- | -------- |
| combo chip power-on | `wifi/power_on_pin`  | 88         | 85       |
| Bluetooth enable    | `bt-dev/gpio_en`     | 99         | 96       |
| Wi-Fi host wake     | `wifi/interrupt_pin` | 100        | 97       |
| second LED          | `gpioleds/sys_red`   | 76         | 73       |

Ophub's gxl tree carries `reset-gpios = <... 0x55 0x01>` — 85 — and would have given this in one
diff. Translating a vendor pin index arithmetically is the wrong move; read it off a mainline tree
or off the box.

The same error had the standby LED on GPIODV_27 instead of GPIODV_24, which is why nothing lit. The
board has one two-pin LED, so the second entry is very likely describing a part that is not fitted —
the factory tree is a generic Amlogic reference and full of blocks this box does not have.

### The MT7668 is not an MT7663 with a different id

With the power-on pin corrected the chip resets properly at every boot, and the driver gets far
enough to show what it had been hiding. Six distinct faults, each one masking the next:

1. **The SDIO RX kthread took a NULL dereference at probe.** The part raises RX1, which the MT7663
   path never allocates, so `q->entry` is NULL and serving it kills the worker — after which nothing
   delivers MCU responses and every later command times out. This is what "mute MCU" was.
2. **The patch semaphore was read as fatal.** `PATCH_NOT_DL_SEM_FAIL` means "not yours yet"; the
   vendor polls it fifty times at 100 ms. mt76 asks once.
3. **The RAM code is in MediaTek's own container**, a fixed ILM/DLM descriptor pair at the end of
   the file with a four-byte CRC after each section — not the MT7663's region table. Read as the
   latter, the driver asks the chip to take a 1.4 GB region at `0x9135933b`.
4. **Nothing waits for a section to land.** The scatter loop returns when the last chunk is queued
   and the SDIO queue is 256 deep, so the next request is dropped.
5. **N9_RDY in `MT_CONN_ON_MISC` reads zero on this part however far the firmware has got.** The
   MT7668 reports through `WCIR_WLAN_READY`, bit 21 of SDIO register 0x0000, and raises it once the
   CR4 image is in. It never answers the CR4's own start request.
6. **Register access goes through the MCU once firmware is running**, and this firmware does not
   implement `MCU_CE_CMD_REG_READ`. MediaTek's driver uses the mailbox for the part's whole life.

Firmware now downloads in full — patch, N9 ILM+DLM, N9 start, CR4 ILM+DLM — and the part raises
`WCIR 0x00307668`, ready. Fault 6 is fixed in the tree but not yet run on hardware.

### How fault 6 wedges the box

`ip link set wlan0 up` holds `rtnl` while `mt7615_start()` runs, and with register reads costing a
twenty-second MCU timeout each it never returns. `rtnl` stays held; glibc's name lookups query
netlink, so sshd accepts the connection and then never sends its banner, and the serial console has
no getty to fall back to. Magic SysRq over a serial break does not answer either. Only a power cycle
recovers it.

Worth knowing before the next `up` on a part whose MCU is not answering.

## 2026-09-17 (later) — firmware runs; the runtime command set does not answer

With the power-on GPIO corrected and the download path fixed, the part loads its whole firmware and
reports itself ready. What it will not do is answer a command.

### What the part does

| Step                                                  | Result                        |
| ----------------------------------------------------- | ----------------------------- |
| ROM patch, N9 ILM+DLM, N9 start, CR4 ILM+DLM          | every command answered        |
| `WCIR` after the CR4 image is in                      | `0x00307668`, WLAN_READY set  |
| mailbox read of `MT_CONN_ON_MISC`, every 2 s for 22 s | `0x01000000`, never a timeout |
| any `MCU_EXT_CMD`                                     | no answer, ever               |
| the part after one `MCU_EXT_CMD`                      | mailbox stops answering too   |

The part is healthy for as long as nothing asks it anything. The first ext command kills it.

### What that is not

Each of these was tested on hardware and made no difference:

- **A lost first command.** MediaTek's driver sends `CMD_ID_DUMMY_RSV` here and calls it a
  workaround for the capability command being lost. Sent; the next command still failed.
- **The destination.** The vendor addresses runtime commands to `S2D_INDEX_CMD_H2N_H2C`, mt76 to
  `MCU_S2D_H2N`. Changed; no difference.
- **`ext_cid_ack`.** mt76 sets it on every ext command; the vendor leaves the same byte zero.
  Cleared; no difference.
- **The EEPROM.** The efuse reads blank, so the driver was uploading zeroes and taking a random MAC.
  The factory EEPROM now loads and `wlan0` carries its address, `00:0c:43:26:60:48`. The part still
  dies on the upload.
- **The upload's shape.** The vendor's header is `01 ff 01 00` - source mode, a count its format
  ignores, and a command type selecting the 7668 format - over the 416-byte calibration window at
  `0x3a`. mt76 sends a mode, a format and a 16-bit length over the whole EEPROM, so the length's low
  byte lands on the command type. Corrected; no difference.
- **That command in particular.** Skipped entirely, and the next ext command failed the same way.
- **`EXT_CMD_ID_NIC_CAPABILITY` (0x09)**, the one ext command MediaTek's driver sends this part at
  boot: also unanswered.

Command ids are not the problem either - `0x21`, `0x25`, `0x26`, `0x2a`, `0x32` mean the same in
both drivers, and `0xed` is `CMD_ID_LAYER_0_EXT_MAGIC_NUM` in the vendor tree. The command reaches
the chip: the queue drains and the scheduler quota falls, 32 to 24 to 23.

### What is left

The difference has to be in what the host does between starting the firmware and speaking to it. The
vendor does two things there that mt76 does not: it re-reads the interrupt status and the released
TX counts, and it re-queries and resets the TX resource accounting
(`wlanQueryNicResourceInformation`, `nicTxResetResource`) before its first real command. Its init
commands go out on TC4 and its runtime commands do not. That is the next thing to test.

## 2026-09-17 (later still) — reading the driver Amlogic shipped

`wlan_mt76x8_sdio.ko` comes out of the vendor partition of the eMMC dump with `e2cp`. It is a 32-bit
ARM module, **not stripped**: 2219 named functions, built from
`amlogic/S905L2/code/hardware/wifi/mtk/drivers/mt7668/drv_wlan/MT6632/`, reporting
`WiFi Driver Version 2.0.0` - the same version as the gen4m source read against here, so that source
is the right generation and not the newer tree its bundled firmware suggested.

Disassembling the two functions that put a command on the wire gives the format directly.

`wlanConfigWifiFunc`, which starts the firmware:

| Offset | Written            | mt76 writes |
| ------ | ------------------ | ----------- |
| 0x00   | byte count         | same        |
| 0x02   | PQ id `0x8000`     | same        |
| 0x24   | CID                | same        |
| 0x25   | packet type `0xa0` | same        |
| 0x27   | sequence           | same        |
| 0x40   | payload            | same        |

`wlanSendSetQueryExtCmd`, which sends every runtime command:

| Offset | Written                      | mt76 writes       |
| ------ | ---------------------------- | ----------------- |
| 0x20   | length, total minus 32       | same              |
| 0x22   | PQ id `0x8000`               | same              |
| 0x24   | `0xed`, the ext magic        | same              |
| 0x26   | set/query                    | same              |
| 0x29   | ext command id               | same              |
| 0x2b   | left zero                    | `ext_cid_ack = 1` |
| 0x2a   | set to 3 later in `nicTxCmd` | `MCU_S2D_H2N`     |

Both differences are now carried in `0016`. The part still answers nothing.

So the header is not it. mt76 puts the same bytes on the bus as the driver that works, which is
worth knowing: what is left is below the header - how the packet is written to the bus, or some chip
state the vendor establishes and this driver does not. That is not reachable by reading structs, and
the next thing that would actually produce information is a capture of the vendor driver's SDIO
traffic for one command.

## 2026-09-18 — the vendor driver answers where mt76 does not

mt76 never got a single runtime command answered. MediaTek's own driver gets dozens, so the radio is
being brought up on that, and mt76 becomes the thing to fold back into rather than the way in.

The module the box shipped with comes out of the dump unstripped - 2219 named functions, driver
version 2.0.0 - which is the same generation as a third-party port of that tree to Armbian 6.1
aarch64. That port builds on 6.18 with four API changes, all in the Bluetooth half.

With it loaded, and Bluetooth held back:

| Result                   |                                                  |
| ------------------------ | ------------------------------------------------ |
| `wlan0`, `p2p0`, `ap0`   | present, carrying the EEPROM's address           |
| firmware program counter | in the ILM at `0xe00xxxxx`, advancing            |
| firmware asserts         | none                                             |
| scan                     | 21 networks, "Sormy Net" among them              |
| association              | `REQ_CHANNEL_JOIN` never granted, auth times out |

**Bluetooth and Wi-Fi cannot be loaded in parallel.** `bt_mt7668` probing during Wi-Fi init asserts
the firmware's shared WMT task - `<ASSERT> system/cos/cos_api_t.c #1005 ... id=0x0 WMT` - and takes
both radios down. That single shared task is why Bluetooth reported `wmt command timed out` through
every mt76 experiment: one component failing, two symptoms.

Two things found along the way that the mt76 work had no way to see:

- Every channel reports 0 dBm until `Country` is the literal `00` in `wifi.cfg`. The power table is
  matched with `rlmDomainAlpha2ToU32("00")`, `0x3030`, against a country code that is `0x0000` when
  unset, so the only table in `TxPwrLimit_MT76x8.dat` is unreachable.
- `kalIsConfigurationExist()` is false, so manufacture data never loads: the driver wants an Android
  NVRAM partition this image does not have.

The box now carries a watchdog that reboots it when the rtnl lock has been held long enough to
strand sshd, which a driver stuck under it does. Three power cycles were spent on that before it
existed.

## 2026-09-18 — the EEPROM is not this board's

`EEPROM_MT7668.bin` out of this box's Android and the copy carried by an unrelated S905L2 port are
byte-identical - 1024 of 1024, MAC included. It is MediaTek's reference blob, not per-unit
calibration, and the `00:0c:43:26:60:48` the driver reports from it is a vendor default every MT7668
loading this file would share.

The factory does not use it for addressing. `mac-addresses.txt` has Android's `wlan0` at
`b2:14:26:85:16:d0`, locally administered, and records that neither `mac_wifi` nor `mac_bt` exists
in storage - both are derived. So this board has no stored Wi-Fi MAC, and anything that ships the
blob needs its own derivation, the way `rk35xx-mac-pin` does elsewhere in this repo.

That also settles where the blob belongs: not nvmem and not MTD, which describe per-unit storage
that is not there, and not a kilobyte of hex in every board's device tree either.

## 2026-09-19 — Wi-Fi associates and passes traffic

The vendor driver had stopped probing entirely - `Patch status check timeout`, then
`halRxWaitResponse fail!`. It was not a regression in anything this repo changed: mainline
`btmtksdio` binds SDIO function 2 at boot, its WMT command times out, it gives up with
`Failed to power on data RAM (-110)`, and the chip's shared firmware path is wedged from then on.
The Wi-Fi driver loads 27 seconds later into that wreckage. `blacklist btmtksdio` and it probes
clean.

Rebinding `meson-gx-mmc` is not a substitute for a power cycle: the card re-enumerates, both
functions come back, and the part is still in whatever state the last driver left it. Swapping
between mt76 and the vendor driver needs a reboot.

With a clean chip the driver reaches:

    wpa_state=COMPLETED   Connected to 74:90:bc:12:33:90   freq 2437   signal -44 dBm
    tx bitrate: 144.0 MBit/s   WPA: Key negotiation completed [PTK=CCMP GTK=CCMP]

and passes traffic - ARP resolves, ICMP round-trips, `ip -s link` counts real packets both ways.

**It is not reliable yet.** From a clean boot the usual outcome is a loop of
`Authentication with 74:90:bc:12:33:90 timed out`; the run that worked had been retrying for about
twenty minutes first. What does not reproduce the good state, each tried and measured:

| Tried                                             | Result                      |
| ------------------------------------------------- | --------------------------- |
| netdev down/up before `wpa_supplicant`            | 10 attempts, 0 associations |
| hostapd on `p2p0` to AP-ENABLED, then back to STA | 10 attempts, 0 associations |
| letting it retry for 8 minutes                    | 9 auth timeouts, 0          |
| pinning `bssid=` and `scan_freq=2437`             | 18 attempts, 3 timeouts, 0  |

The run that worked had an AP beaconing on `p2p0` for about four minutes first, so the radio had
been parked on channel 6 that whole time; a six second hostapd run does not set a channel at all
(`iw dev p2p0 info` reports none even at `AP-ENABLED`), which is why the short version proves
nothing. That is a lead, not a fix.

What the failing attempt looks like, all measured rather than inferred: the channel is granted
(`ChGrant net=0 token=10 ch=6`), the BSS carries the right BSSID (`AuthMode[7] EncStatus[6]`), the
StaRec and WTBL entry exist, target TX power is 19-22 dBm on channel 6, TC4 has seven pages and
acquires and releases them cleanly, and the BSS is present (`NAF=0,0,0`). SAA sends AUTH1, the
firmware takes the frame - and never returns `EVENT_ID_TX_DONE` (0x0f). SAA only leaves
`SAA_SEND_AUTH1` on that event, and arms its fallback timer only when the _send_ fails, so AUTH2
would be discarded even if it arrived.

That last part was tested rather than assumed. Patching `saaFsmSteps` to arm the response timer and
enter `SAA_WAIT_AUTH2` on a successful send, instead of waiting for TX_DONE, works mechanically -
the state machine reaches `SAA_WAIT_AUTH2` twice per attempt - and **no AUTH2 ever arrives**.
Receive is not the problem (842 packets on `wlan0` and three IPv6 routers learned over it in the run
that worked), so the auth frame is not reaching the air. The patch was reverted; it only proves
where the fault is not.

Two other things worth knowing: `ucTpTestMode`, which would disable online scan and force CAM mode,
is applied only in the already-connected branch of `aisFsmSteps`, so it cannot affect the auth
phase; and `wpa_supplicant`'s `ap_scan=2` is not usable here, nl80211 warns against it and the BSSID
arrives as zeros.

`TxAllowed[0]` during the attempt is a red herring - `qmUpdateStaRec` holds it false for a protected
BSS until `fgIsTxKeyReady`, by design, and management frames do not go through that queue. So is
`TxQ LEN TC[4]`: the dump prints six entries from a four-entry array, so indices 4 and 5 are
whatever follows it in memory.

Latency is poor when it does connect: a flat ~320 ms floor with 10-20% loss. `iw` reports power save
already off, but `DTIM Period[3]` against 100 ms beacons is 300 ms, and gen4m runs its own power
save that `iw` does not control.

## 2026-09-19 — the chip has its own eFUSE, and it was being overridden

`/proc/net/wlan/efuse_dump` shows the part's eFUSE is programmed, and it does not match the
`EEPROM_MT7668.bin` the driver was loading:

| offset | `EEPROM_MT7668.bin`       | chip eFUSE             |
| ------ | ------------------------- | ---------------------- |
| 0x00   | `68 76 00 00`             | `68 76 00 00`          |
| 0x04   | `00 0c 43 26 60 48`       | `d0 aa 5f 32 eb f2`    |
| 0x0a   | `68 76 c3 14`             | `68 76 c3 14`          |
| 0x10   | 16 bytes not in the eFUSE | continues at file 0x20 |

`wifi.cfg` carried `EfuseBufferModeCal 1`, which makes the driver read that bin and push it to the
firmware **as** the efuse content, so MediaTek's reference blob replaced this unit's own
calibration. Setting `EfuseBufferModeCal 0` and rebooting brings `wlan0` up as `d0:aa:5f:32:eb:f2` -
the eFUSE's own address, matching offset 0x04 exactly.

So the earlier entry needs qualifying. The _file_ is not this board's - it is byte-identical to an
unrelated port's copy. **The chip's eFUSE is.** This board does have per-unit data; it is in the
part, not in storage, and nothing has to derive a MAC after all.

That matters for the mt76 series: patch 0004 reads the EEPROM from a firmware file, which gives
every one of these boxes `00:0c:43:26:60:48`. Reading the part's eFUSE instead is both correct and
what the vendor driver does with buffer mode off.

It did **not** fix association - still `Authentication with ... timed out`, so the reference
calibration was not what kept AUTH1 off the air. Nor did `Nss 1`, tried on the theory that a
two-chain transmit into a single antenna would degrade TX while leaving single-chain RX healthy; it
is reverted, since nothing here establishes how many antennas the board has. `EfuseBufferModeCal 0`
is kept anyway, because a real MAC and this unit's own calibration are the right defaults.

### The SDIO trace instrument

`/sys/kernel/debug/tracing/events/mmc/mmc_request_start` needs no driver changes and decodes fully:
CMD53's argument carries direction in bit 31, function in 30:28, block mode in 27, register address
in 25:9 and the count in 8:0. Across 45 seconds of failing attempts on the vendor driver:

| access        | count |
| ------------- | ----- |
| write `WTDR1` | 60    |
| read `WHISR`  | 34    |
| read `WRDR0`  | 11    |
| read `WRDR1`  | 0     |

Two things fall out. The auth frame **is** written to the chip - the join writes `68, 88, 88` bytes
to `WTDR1` and one of those is it - so the host side is doing its job and the firmware is dropping
it. And the vendor driver never reads rx port 1 at all: every event comes back on port 0, and each
status read is exactly the 112 bytes of the enhanced block. That is worth weighing against the mt76
series, which enables RX1 and allocates a queue for it.

## 2026-09-19 — `cap-sdio-irq` was the fault, and Wi-Fi works

One device-tree property, added by this port and absent from the factory tree, was behind every
symptom. With `cap-sdio-irq` the host takes `MMC_CAP_SDIO_IRQ` and uses the part's in-band
interrupt; firmware events then arrive late or not at all. Removing it drops the host back to
`ksdioirqd` polling, and the difference is not subtle:

| Measured              | with `cap-sdio-irq`                   | without            |
| --------------------- | ------------------------------------- | ------------------ |
| first scan after load | 0 BSSes in 16 s                       | 24 BSSes in 2 s    |
| later scans           | 21 BSSes in 15 s                      | 26 BSSes in 1-2 s  |
| association           | never, `Authentication ... timed out` | 3 s, 0 timeouts    |
| ping to the gateway   | ~320 ms, 10-20% loss                  | 11 ms avg, 0% loss |
| rate                  | 144 Mbit/s                            | up to 300 Mbit/s   |

What it looked like from the driver's side: `aisFsmSteps` reached `REQ_CHANNEL_JOIN`, was aborted,
and the firmware's `ChGrant` for that same token arrived **after** the abort. The channel grant, the
missing `TX_DONE` for AUTH1, and mt76's replies landing one command late are all one fault - events
only collected when the host happens to transact.

Reproduced from a cold boot: associates in 3 s, 20/20 pings. The property is gone from
`board.patch`; the factory tree never had it.

## 2026-09-19 — what the correct `wifi.cfg` is

The box's own Android shipped one, in `/vendor/firmware/wifi.cfg`, 889 bytes. It was never pulled
into the stock dump; it is now, at `stock/h96max-m20/firmware/wifi.cfg`, read out of the vendor
partition with `debugfs`.

It is **byte-identical** to the file the gen4m package ships, with one difference: the factory file
has no `Country` line. So the correct configuration is the factory file plus `Country 00`, which
this port needs because nothing else supplies a country - without it
`rlmDomainSearchRegdomainFromLocalDataBase` fails and every channel reports 0 dBm.

`EfuseBufferModeCal 1` is the factory value, so buffer mode with `EEPROM_MT7668.bin` is what the box
shipped with, and the `EEPROM_MT7668.bin` in `/lib/firmware` is byte-identical to the factory copy.
That closes calibration as a suspect. Setting it to 0 makes the driver use the part's own eFUSE and
report the per-unit MAC instead, which is the only reason to prefer it; it changes nothing else
measurable, so the factory value is kept.

`Nss 1` was tried and reverted - nothing here establishes the antenna count.

## 2026-09-19 — Bluetooth: transport fixed, one command short

Mainline `btmtksdio` now gets much further. `wmt command timed out` and
`Failed to power on data RAM` are gone - that was the same `cap-sdio-irq` fault. It downloads
firmware, completes setup, and registers `hci0` with a real per-unit address, `D0:AA:5F:32:EB:F3`,
the Wi-Fi eFUSE address plus one:

    Bluetooth: hci0: Device setup in 3248996 usecs
    hci0: Type: Primary  Bus: SDIO  BD Address: D0:AA:5F:32:EB:F3
    RX bytes:9176 events:728   TX bytes:188742 commands:760 errors:0

It stops at one command. `Opcode 0x2031 failed: -56` is LE Set Default PHY answered with HCI status
0x01, "Unknown HCI Command" - the part's supported-command bitmap claims it and its firmware rejects
it. That aborts `hci_init_sync`, so the controller never reaches the management layer: `btmgmt info`
reports `Index list with 0 items` and `bluetoothctl` has no default controller. `hciconfig hci0 up`
fails before any HCI traffic reaches `btmon`, which is consistent.

The firmware file was also wrong and is now right. `/lib/firmware/mediatek/mt7668pr2h.bin` held a
copy of `mt7668_patch_e2_hdr.bin`, the Wi-Fi ROM patch; linux-firmware's own blob is a different
170990 byte file, `md5 e560485642874c3cbb93b1fc3ea92c36`, and is installed. It did not change the
0x2031 failure. Note the vendor Android driver genuinely does use `mt7668_patch_e1/e2_hdr.bin` as
its BT firmware, so the identical files were not obviously wrong until the linux-firmware copy was
compared.

Order matters: with the Wi-Fi driver loaded first, BT setup drops from 3.2 s to 43 ms and reports
`function already on`, because the combo part's ROM patch is already in. Loaded before Wi-Fi at
boot, `btmtksdio` still wedges the Wi-Fi side, so it stays blacklisted while the vendor Wi-Fi driver
is in use - which is what MediaTek's own `install.sh` does too.

No quirk in 6.18 covers a controller that rejects LE Set Default PHY; `HCI_QUIRK_BROKEN_LE_CODED`
only masks the coded-PHY bit. The next step is a `btmtksdio` build that stops the core sending it.

### Bluetooth works

`hci_le_set_default_phy_sync()` sends the command purely on `commands[35] & 0x20`, and it is an
`HCI_INIT` entry in `hci_init4`, so the rejection aborts `hci_init_sync()` and the controller is
closed again. Nothing in 6.18 retracts a single claimed command, so `btmtksdio` sets
`HCI_QUIRK_BROKEN_LOCAL_COMMANDS` for `0x7668` and the core stops reading the bitmap at all. Built
out of tree from the 6.18.44 `btmtksdio.c` and installed to `updates/`; the patch is in
`patches/btmtksdio-mt7668/`.

    Bluetooth: hci0: HCI Read Local Supported Commands not supported
    btmgmt info -> Index list with 1 item
      addr D0:AA:5F:32:EB:F3 version 8 manufacturer 70
      current settings: powered ssp br/edr le secure-conn
    btmgmt find -> dev_found E8:FB:1C:66:E9:84 type BR/EDR rssi -79, confirm_name succeeded
    hciconfig -> UP RUNNING, 837 commands, 0 errors

Discovery was verified with `btmgmt find` (type 7, BR/EDR and LE) and with a classic inquiry; both
find the same real device. The quirk is coarse - the core now treats every optional command as
absent - and the right shape is a targeted quirk, which needs a core change this repo cannot carry.

The `mt7668pr2h.bin` correction stands on its own: the file in `/lib/firmware/mediatek` was a copy
of the Wi-Fi ROM patch, and linux-firmware's is a different 170990 byte blob. It is installed,
though with Wi-Fi loaded first `btmtksdio` reports `Firmware already downloaded` and never reads it.

## 2026-09-19 - mainline mt76: three measured fixes, and a pile of dead compensation

Instrumented every MCU send and every event (`cmd`, `seq`, `eid`, `ext_eid`, `len`). Nine
source-reasoned configs had failed 0/5 before any logging existed; two rounds of tracing produced
every fix below.

### The ROM patch was landing at the wrong address

gen4m takes it from `prChipInfo->patch_addr`: `MT6632_PATCH_START_ADDR 0x000B4000`,
`MT7668_PATCH_START_ADDR 0x000C8000`. mt76 used `MT7663_PATCH_ADDRESS 0xdc000` for this part.

|                   | before                  | after            |
| ----------------- | ----------------------- | ---------------- |
| firmware download | 40-80 s, usually failed | 13 s, every boot |
| firmware asserts  | `RB_FULL` every boot    | 0                |

This is the change the rest of the session has to be re-read against: several earlier workarounds
were compensating for a firmware that had been patched into the wrong place.

### The CR4 start request is answered after all

`mt7668_load_ram()` sent `MCU_CMD(FW_START_REQ)` for the CR4 with `wait=false` and the comment "the
CR4 takes over on this one and never answers it". The trace disproves it: the reply arrives 514 ms
later, after `__mt7663_load_firmware()` has already returned, and the next command takes it.

    tx cmd=00000002 seq=10
    TRC quota ...                 <- mt7663s_mcu_init_sched, already past the send
    rx eid=01 seq=10              <- 514 ms
    tx cmd=000021ed seq=11
    Message 000021ed answered out of sequence: want 11, got 10

Deleting the special case - so both branches use `mt76_connac_mcu_start_firmware()` - removes the
out-of-sequence reply entirely.

### Pinning the part to the mailbox was causing the firmware asserts

Patch 0005 made `mt76s_reg_via_mcu()` return false for `0x7668`, on the grounds that its firmware
has no `MCU_CE_CMD_REG_READ`. That was measured while the ROM patch was landing at the wrong
address, and the ROM patch is what adds the command. With the address corrected, MCU register reads
are answered in 13-20 ms, and removing the pin gives:

    fwdump lines: 0      query whisr timeout: 0      wlan0: present

The mailbox busy-polls read-clear `WHISR` from the caller's thread while the rx worker reads the
same register; after `MT76_STATE_MCU_RUNNING` the driver issues enough register access for the two
to collide, the mailbox loses its own completion bit, the host stops draining, and the firmware
fills its event ring and asserts `!RB_FULL( (*q_id) ), id=0x2`.

### The part implements a smaller command table

mt76's mt7615 sends ext commands up to `0x7d`. gen4m's MT7668 table stops at
`EXT_CMD_ID_EFUSE_FREE_BLOCK 0x4F`, and the part answers nothing outside it - no error event, just
silence, so each unknown command costs the full 20 s timeout.

Absent here: `ATE_CTRL 0x3d`, `PROTECT_CTRL 0x3e`, `DBDC_CTRL 0x45`, `MAC_INIT_CTRL 0x46`,
`RX_HDR_TRANS 0x47`, `MUAR_UPDATE 0x48`, `BCN_OFFLOAD 0x49`, `SET_RX_PATH 0x4e`,
`TX_POWER_FEATURE_CTRL 0x58`, `RXDCOC_CAL 0x59`, `TXDPD_CAL 0x60`, `CAL_CACHE 0x67`,
`SET_RADAR_TH 0x7c`, `SET_RDD_PATTERN 0x7d`.

The low range is the same dialect - `0x21` `0x25` `0x26` `0x27` `0x2a` `0x32` match by name - so
this is a smaller table rather than a different protocol. One id collides: `0x3a` is `SET_RDD_CTRL`
to mt76 and `PALLADIUM` to gen4m.

Nothing the part emits enumerates its command set. `NIC_CAPABILITY 0x09` exists on both sides, but
its TLVs are TX resource, efuse address, coex, single SKU, checksum offload, MAC efuse offset and
R-mode - no command table. Capability has to be declared or learned from a timeout.

## 2026-09-20 - mainline mt76 scans

The port reaches a scan. `iw dev wlan0 scan` returns 18-24 BSSes on the first call after the
interface comes up; later calls return none. Boot is clean - no firmware assert, no MCU timeout, no
register access at all - and the firmware is down in 13 s every time.

### The ablation

Six of the eight changes carried into this session turned out to be compensating for the ROM patch
address, and were removed with no measured effect:

| Removed                                                | Boot after |
| ------------------------------------------------------ | ---------- |
| preserving rx bits stolen from the read-clear `WHISR`  | clean      |
| pacing the firmware download, draining between slices  | clean      |
| taking the rx length from `WRPLR`                      | clean      |
| the per-section drain and mailbox round trip           | clean      |
| spending a sequence only on commands that draw a reply | clean      |
| rewriting `WHCR`/`WHIER`, restarting a resident N9     | clean      |

`FW_SCATTER seq=0` was among them: out-of-sequence replies stay at zero without it.

### Two categories of command, not one

Commands the firmware does not answer split in two, and treating them alike fails either way.
Sending one it does not implement is not harmless - with `MAC_INIT_CTRL`, `SET_RX_PATH`, `DBDC_CTRL`
and `SET_RATE_TX_POWER` on the wire, the `DEV_INFO_UPDATE` after them stops being answered. Not
sending one it does implement loses the function. The mechanism now says which.

### The part runs its own scan

`fw_ver = MT7615_FIRMWARE_V2` was this port's own guess, and it makes mt76 tear out `hw_scan` and
fall back to a software scan the part cannot do. gen4m scans with `CMD_ID_SCAN_REQ_V2 0x03`, which
is mt76's `MCU_CE_CMD(START_HW_SCAN)`. Marking the part offload-capable while keeping the ext
command station path is what produced the first scan results.

### Measured and rejected

`REG_WRITE` acknowledgement: this firmware answers no register write, so mainline's `wait=false` is
right. Caching registers that fail to answer: `MT_WF_RMAC_MIB_TIME0` answers at boot and not once
the part is busy, so the cache marks good registers dead.

### A measurement error worth recording

`fastbuild.sh` piped `make` into `tail`, so `set -e` saw tail's status and a failed build silently
reinstalled the previous module. Two results were read off stale modules before the missing
`set -o pipefail` was found. The trigger was `FIELD_PREP` in a static initializer, which the
compiler rejects as a braced-group outside a function.

### One scan per firmware load

The second scan request is sent and is byte-identical to the first - same 960 bytes, same seq once
forced, same channel list - and the part answers neither with an event nor an error.
`MT76_HW_SCANNING` therefore stays set and every later scan is refused `-EBUSY`.

    86.28  hw_scan issued
    88.54  ev eid=0d          <- SCAN_DONE, scan 1 completes
    88.65  scan completed
    88.67  hw_scan issued     <- scan 2: no event, ever

`rmmod mt7663s; modprobe mt7663s` does not clear it: `WIFI_RAM_CODE_MT7668.bin` is loaded once per
boot and the firmware stays resident across a driver reload. Only a reboot restores scanning, so the
state that blocks the second scan is the firmware's.

Ruled out by measurement: the sequence number (forced constant, same result), the request length
(826 and gen4m's 960 both behave alike), a 45 s gap between scans, a single-frequency scan, a
passive scan, and an interface down/up cycle.

Sending the version 1 scan request - mt76's default, 1186 bytes against gen4m's 960 - is what made
the part stop answering `DEV_INFO_UPDATE`, `BSSINFO_UPDATE` and `STAREC_UPDATE` after a scan. The
version 0 form leaves no MCU timeout anywhere through boot, interface up and repeated scans.

`ieee80211_hw_conf_init()` was warning because `mt7615_config()` returned `-ETIMEDOUT` from
`CHANNEL_SWITCH`. gen4m never sends that command - it is an enum entry with no sender - and the same
is true of `EDCA_SET`, `WTBL_UPDATE`, `PM_STATE_CTRL` and `FW_LOG_2_HOST`. Whether gen4m sends a
command turns out to be the reliable test of whether this firmware implements it: the four it does
send - `EFUSE_BUFFER_MODE`, `DEVINFO_UPDATE`, `STAREC_UPDATE`, `BSSINFO_UPDATE` - are the four that
are answered.

Build note: `rsync --checksum` in the out-of-tree build keeps unchanged files' timestamps, which
takes a rebuild from 7m34s to 1m18s.

## 2026-09-20 - scanning works, repeatably

Six consecutive `iw dev wlan0 scan` calls return 17-30 BSSes with no MCU timeout, from the repo
patch set alone. Two bugs, both in the SDIO transmit credit accounting.

`pse_mcu_quota` was draining and never refilling:

    pse_mcu=19 -> 18 -> 16 -> 15 -> 6

Each scan request is 1024 bytes, nine pages. Starting from the 32 that `mt7663s_mcu_init_sched()`
reads out of the part, three scans exhaust it; the fourth is queued and never sent, which is why the
part saw only the first request and why nothing anywhere reported an error.

**The part returns its command credits on TQ15.** The status block counts sixteen transmit queues
two to a word, and `mt76s_refill_sched_quota()` reads the command queue's from `data[2]` - TQ4.
Tracing the whole array showed `wtqcr[7] = 0x00010000`, TQ15, one credit per completion, while TQ4
stayed zero for the part's whole life.

**It returns one credit per command, not per page.** mt76 already knows parts like this:

    if (mcu && sdio->hw_ver == MT76_CONNAC2_SDIO)
            pse_sz = 1;

This part is CONNAC v1, so it was charged nine pages per command against credits handed back one at
a time. Reading TQ15 alone got three scans instead of one; charging per command as well holds the
quota at 32 indefinitely.

Both are expressed as fields a driver sets, so the parts already supported keep the counter and the
accounting they use today.

Ruled out along the way, each by measurement: the scan sequence number, the request length, a 45 s
gap between scans, a single-frequency scan, a passive scan, an interface down/up cycle, and a driver
reload. The firmware's own scan state in the done event read `state=7`, `FW_SCAN_STATE_SCAN_DONE`,
all 32 channels complete - it had finished cleanly and was waiting for a request that never arrived.

### Next

`wpa_supplicant` stays in `SCANNING` and does not associate, and after it has run, scanning stops
until the next boot. The configured network is pinned to a BSSID that did not appear in any scan.

### Association: the radio is never tuned

`wpa_supplicant` gets further than it first appeared. Its debug log shows it selecting the right AP
and negotiating ciphers:

    wlan0: selected BSS 74:90:bc:12:33:90 ssid='Sormy Net'
    nl80211: Authentication request send successfully
    wlan0: SME: Authentication timed out

The authentication frame reaches the part - three retries at ~300 ms, `pse=256 ple=403` untouched,
so nothing is short of transmit credit - and draws no reply. `iw dev wlan0 info` prints no channel
line at all: nothing has tuned the radio, and a host-originated frame goes out wherever the last
scan left it. Scanning is unaffected because the firmware picks its own channels for a scan.

`CHANNEL_SWITCH 0x08` does not tune it. Sent and waited it times out; sent without waiting it is
ignored; declared absent it changes nothing. gen4m never sends it either - it is an enum entry with
no sender - and asks for a channel with `CH_PRIVILEGE`, which is mt76's `MCU_CE_CMD(SET_ROC) 0x1c`.
That is the next thing to implement.

Two earlier readings were wrong and are corrected here. The part does see the AP: `Sormy Net` and
BSSID `74:90:bc:12:33:90` are both in its scan results, and the earlier "not visible" was taken
after `wpa_supplicant` had already stopped scanning from working. And "sending `CHANNEL_SWITCH`
without waiting breaks the first scan" was an artefact of the transmit-credit bug, not of the
command: with credits fixed, scanning is unaffected either way.

`WTBL_UPDATE 0x32` is answered after all and is no longer declared absent. It was classified from
gen4m's enum having no sender for it, but the timeout that suggested it came from
`mt76_connac_mcu_del_wtbl_all()`, a reset-all the part does not take; ordinary station updates are
answered.

### The untuned-radio theory was wrong

`iw dev wlan0 info` printing no channel is not evidence of anything: the vendor driver prints none
either while unassociated, and it associates from that state - `wpa_state=COMPLETED`, connected to
`74:90:bc:12:33:90` on 2437 MHz. The theory was built on that reading and is withdrawn.

Acting on it made things worse. Asking for the channel with a `CH_PRIVILEGE` request - gen4m's
`CMD_CH_PRIVILEGE_T` is byte-identical to mt76's `struct mt7615_roc_tlv`, `CMD_CH_ACTION_REQ` is 0
where mt7615 writes `active = !chan`, and `EVENT_ID_CH_PRIVILEGE 0x10` is `MCU_EVENT_ROC` - dropped
scan results from 27 to 3 and changed nothing about association. Reverted.

So association is still open with no working theory. What is known: the authentication frame leaves
the driver, the part is not short of transmit credit, the AP is on 2.4 GHz channel 6, and the part
can see it. What is not known is whether the frame reaches the air.

Settling that wants a capture of the vendor driver's SDIO writes across a successful join, which is
the one instrument this port has never had.

## 2026-09-20 - wireless throughput, and the regulatory deadlock fixed

Measured against `iperf3` on the LAN host, wlan0 given its own address and routing table so the
traffic cannot leave over Ethernet.

| Band    | Associates | Signal  | Link rate  | TX        | RX        | Ping      |
| ------- | ---------- | ------- | ---------- | --------- | --------- | --------- |
| 2.4 GHz | ✅ 2 s     | -44 dBm | 144 Mbit/s | 91 Mbit/s | 89 Mbit/s | 28 ms avg |
| 2.4 GHz | ✅ 2 s     | -48 dBm | 144 Mbit/s | 74 Mbit/s | 66 Mbit/s | 16 ms avg |
| 5 GHz   | ❌         | -       | -          | -         | -         | -         |

Two 2.4 GHz runs are given because they differ: the weaker signal is the rebuilt driver, and the gap
is signal, not the build. Ping is 9-24 ms and never lost a packet.

### `iw reg set` no longer strands the box

The regulatory deadlock the todo describes is real and I walked into it: `iw reg set US` held rtnl
forever and sshd stopped answering, costing a power cycle. `wiphy_apply_custom_regulatory()` takes
`rtnl_lock()`, and cfg80211 calls the notifier holding it.

Dropping that call from `mtk_reg_notify()` - `patches/gen4m-mt7668/0004` - fixes it. `iw reg set US`
returns 0, the domain becomes `country US: DFS-FCC`, the box stays up, and 2.4 GHz still associates.

### 5 GHz still does not associate

At `country 00` every 5 GHz channel is `PASSIVE-SCAN`/no-IR and `wpa_cli scan_results` held none of
them, so `wpa_supplicant` sat in `SCANNING`. With `country US` the 5 GHz BSS appears in its results
and it still does not associate.

`iwpriv wlan0 driver "GET_CNM"` reports `0 CHs in BAND0, 0 CHs in BAND1`: the firmware has no
channel to grant. 2.4 GHz works in spite of that. Closing that gap is step 2 of the regulatory todo
and is what 5 GHz waits on.

## 2026-09-20 - both bands, and a quiet log

5 GHz was never broken. The stock `wpa_supplicant-wlan0.conf` carries `scan_freq=2437` and a 2.4
GHz-only `freq_list`, so wpa_supplicant rejected every 5 GHz BSS with
`skip - frequency not allowed`. Dropping both keys associates in 2 s at 5200 MHz, -38 dBm, 866
Mbit/s link rate, 154/141 Mbit/s. Everything inferred from the earlier failure - the untuned radio,
the `CH_PRIVILEGE` theory, "the firmware holds no channels" - was chasing that configuration.

Numbers for both bands, idle and under load, are in `board.md`.

### The vendor driver no longer fills the log

91 driver lines a boot, with five `memcpy: detected field-spanning write` backtraces from firmware
download and one `dev_addr_check` backtrace per association. Four patches, `gen4m-mt7668/0004` to
`0007`:

| Fix                                            | Effect                          |
| ---------------------------------------------- | ------------------------------- |
| no regulatory domain applied from the notifier | `iw reg set` stops stranding it |
| command buffers take flexible array members    | no fortify backtrace            |
| netdev address set with `dev_addr_mod()`       | no `dev_addr_check` backtrace   |
| the driver's own log carries errors only       | 91 lines a boot to 6            |

Both drivers now boot with no backtrace and nothing repeated. The six lines left are named in
`board.md` with the reason.

A `pr_info("DBGEVT ...")` pair in `nic/nic_rx.c` turned out to be debugging added on the box earlier
in this project, never part of the vendor source or any patch; removing it restores the file.

### Validation

`wlan0` `00:0c:43:26:60:48` and `hci0` `D0:AA:5F:32:EB:F3` identical across three reboots, `hci0`
`UP RUNNING` with `errors:0` each time and `btmgmt find` returning a real device. No latch on either
band: the first measurement after the load stops is already at baseline.

## 2026-09-20 - the command table, and where the eFUSE read cannot go

### The absent-command table is right, the learning was not

With transmit credits fixed, an experiment seeded nothing and let the runtime learning discover what
the firmware refuses. Boot came up with no timeout at all, which looked like the table had been an
artefact — but bringing the interface up then failed once per attempt, learning one command each
time, and what it learned included `STA_REC_UPDATE 0x25`, `BSS_INFO_UPDATE 0x26` and
`DEV_INFO_UPDATE 0x2a`: the three commands gen4m does send and that answer here.

They timed out only because an earlier failure cascaded. A timeout is not evidence of absence, so
the learning was marking working commands dead — the same mistake as the dead-register cache removed
earlier. Both are gone now. The table stands on gen4m's own command enum, which is independent of
anything measured during a failure.

### The eFUSE read has nowhere to go yet

`EXT_CMD_ID_EFUSE_ACCESS 0x01` takes an address, a valid flag and a 16-byte block, and the MAC sits
at offset 4. Implemented it in `mt7615_eeprom_init()` and probe died: that function runs inside
`mt7663s_probe()` → `mt7663_usb_sdio_register_device()`, before MCU init, so `mcu_ops` is unset.
Reverted. The read needs a hook between MCU init and `mt76_register_device()`, and the SDIO path has
none.

### Not comparable yet

A like-for-like driver comparison - same blob, same address, throughput and CPU on both bands - is
not possible while mt76 does not associate. Every number in `board.md` is the vendor driver's.

## 2026-09-20 (later) - Bluetooth works, the blacklist is obsolete, and the MAC theory is dead

### Bluetooth is up, and it coexists with mt76

`btmtksdio` was blacklisted in two hand-made drop-ins on the box, the note reading "btmtksdio
probing function 2 at boot wedges the Wi-Fi side of the combo part". That is no longer true. With
both blacklist lines commented out and the box rebooted:

    hci0    UP RUNNING, errors:0, bd_addr D0:AA:5F:32:EB:F3
    btmgmt find   2 devices
    iw scan       15, 24, 28 BSSes across three runs
    dmesg         0 lines matching timeout or -110

The observation the blacklist was written for predates the transmit-credit and mailbox-polling
fixes. Loading BT after Wi-Fi by hand works too, so nothing depends on ordering any more. Neither
drop-in ships from the repo — both are bring-up scaffolding.

`hci0` takes `D0:AA:5F:32:EB:F3` from the chip, one above the eFUSE `d0:aa:5f:32:eb:f2`. The
Bluetooth half already has a per-unit address; only Wi-Fi is on the shared blob address.

### The auth failure is not the MAC

Association still fails the same way — `send auth (try 3/3)`, then `authentication timed out`. The
theory that the hardware RX filter is programmed from the eFUSE while mac80211 transmits as the blob
address, so the AP's reply is discarded, is **wrong**. Set the netdev to the eFUSE address and
retry:

    wlan0: authenticate with 74:90:bc:12:33:90 (local address=d0:aa:5f:32:eb:f2)
    wlan0: send auth to 74:90:bc:12:33:90 (try 1/3 … 3/3)
    wlan0: authentication with 74:90:bc:12:33:90 timed out

Same failure, correct channel (`set_channel ch 6` for the AP's 2437 MHz). The MAC is a uniqueness
problem, not the blocker.

### `modprobe -r` is not a chip reset

Reloading `mt7663s` sometimes leaves the part unreset and the next firmware download dies:

    Failed to get patch semaphore: -110
    failed to load mediatek/mt7668_patch_e2_hdr.bin
    MCU init failed: -11

What does reset it is unbinding and rebinding the SDIO host, which power-cycles the card through
`sdio-pwrseq` (`mmc-pwrseq-simple`, `reset-gpios`):

```sh
echo d0070000.sdio > /sys/bus/platform/drivers/meson-gx-mmc/unbind
echo d0070000.sdio > /sys/bus/platform/drivers/meson-gx-mmc/bind
```

Firmware then loads cleanly every time. Repeated unbind cycles do eventually leave `mt7663s` unable
to insert with `Device or resource busy`; a reboot clears that.

### Corroborated: the three commands are fine

`STA_REC_UPDATE 0x25`, `BSS_INFO_UPDATE 0x26` and `DEV_INFO_UPDATE 0x2a` all return 0 on a freshly
power-cycled chip, and only go `-110` once an earlier failure has cascaded. Scanning likewise
repeats fine — three consecutive scans returned 16, 21, 23. The `-16 EBUSY` that looks like a broken
second scan is cfg80211 holding a scan request that a failed association never completed.

## 2026-09-20 - why mt76 cannot associate: the wrong command space

### A blocking register read was hiding everything else

`mt7615_set_channel()` ends with `phy->chfreq = mt76_rr(MT_CHFREQ)`. This part does not answer that
register. Every channel set therefore cost a full MCU timeout, and because a timed-out command puts
the mailbox out of step, the `BSS_INFO_UPDATE`, `STA_REC_UPDATE` and `DEV_INFO_UPDATE` behind it
timed out too - four in a row, twenty seconds each, until the driver gave up and reloaded the
firmware. `chfreq` is only ever compared against a channel number, so under `fw_owns_mac` it comes
from the chandef instead. An association attempt now leaves a clean log.

That read also poisoned the evidence. Entries had been added to the absent-command table because
they timed out, when what timed out was the queue behind the stalled read. Re-tested with it gone:
`CHANNEL_SWITCH` and `EDCA_UPDATE` wedge the driver when sent, and ext `FW_LOG_2_HOST 0x13` times
out on its own, so those three are genuinely absent.

### mac80211 hands over the station after the authentication, not before

No `sta_add` reached the driver before the authentication went out. `drv_sta_state()` calls
`drv_sta_add()` on the `AUTH`→`ASSOC` transition for a driver carrying the older `sta_add`/
`sta_remove` ops, which `mt7615_ops` does - so `mt7615_mac_sta_add()`, which is what sends
`BSS_INFO_UPDATE` and `STA_REC_UPDATE`, runs only once the part is already authenticated. Giving
mac80211 `mt76_sta_state` instead puts both ahead of the authentication. Both are answered. Nothing
else changed.

### It is not a transmit problem

The transmit queue advances by three and the credit pool drops by three pages across the three
authentication retries, so the frames are taken. During `AUTHENTICATING` the `last seen` stamp for
the target BSS does not advance, though that AP is at -31 dBm and beacons every 100 ms: the part is
not listening on the operating channel.

### The commands mt76 sends are not the ones this firmware acts on

gen4m sets up a connection entirely in the CE space with flat structures -
`CMD_ID_BSS_ACTIVATE_CTRL 0x11`, `CMD_ID_SET_BSS_INFO 0x12`, `CMD_ID_UPDATE_STA_RECORD 0x13` - and
it is `0x12`, through its `rBssRlmParam`, that carries the band, primary channel, secondary offset
and bandwidth. On this firmware the operating channel is a property of the BSS.

mt76 sends the ext-space TLV commands `BSS_INFO_UPDATE 0x26`, `STA_REC_UPDATE 0x25` and
`DEV_INFO_UPDATE 0x2a`. The part answers all three with success and acts on none. What already works
here is CE: the offloaded scan is `CMD_ID_SCAN_REQ_V2 0x03` and the channel privilege is
`CMD_ID_CH_PRIVILEGE 0x1c`.

### Measured against an association attempt, and not the cause

The channel privilege with the band numbered as the part numbers it (`BAND_2G4` is 1, not
nl80211's 0) is granted and the radio still does not listen. `BSS_INFO_RF_CH` in gen4m's 8-byte
shape is accepted with no effect. Sending management frames to the MCU port as
`TXD_PKT_FORMAT_COMMAND` with no descriptor appendix, as gen4m does, changes nothing - which fits,
since the frames were already leaving the part.

### Iterating

`modprobe -r` leaves the firmware resident and the next probe cannot take the patch semaphore;
unbinding and rebinding `d0070000.sdio` runs the `sdio-pwrseq` reset and the part comes back
identical to a cold boot. With that, one build-and-measure cycle is about ninety seconds rather than
the seven minutes a reboot cost.

### The CE connection path, implemented and measured

`BSS_ACTIVATE_CTRL 0x11`, `SET_BSS_INFO 0x12` with its RLM block, `UPDATE_STA_RECORD 0x13` and
`SET_RX_FILTER 0x0a`, with sizes and offsets taken by compiling gen4m's own structures for the
target ABI rather than counting padding by hand - 12, 116, 136 and 68 bytes. The part receives while
authenticating with them in place, where before its receive queue moved only during a scan, so
something in them reaches the radio. The authentication is still unanswered.

It cannot be settled from the host whether the part accepts them: gen4m sends every one with
`fgNeedResp = FALSE`, so a firmware that works and a firmware that ignores the command look the
same, and making them wait only spends the MCU timeout. The instrument that would settle it is the
firmware log, which is `FW_LOG_2_HOST 0xc5` in the CE space - mt76 only ever sends the ext `0x13`,
which this part does not implement.

Only the `MT_CHFREQ` fix is folded into the patch set, because it is the only part of this that is
proven. The connection code itself is not kept - it never beat the driver without it, and one shape
of it crashed the firmware.

### A day lost to a bad instrument

`iw dev wlan0 scan dump` prints a `last seen` stamp per BSS, and it was read as "does the part hear
this AP". It is not: mac80211 refreshes that only while scanning, so it is frozen during an
association attempt whatever the radio is doing. Several conclusions were drawn from it and are
withdrawn. The receive counter in `/sys/kernel/debug/ieee80211/phy*/mt76/rx-queues` is the real
test - it advances during a scan and is frozen at idle, which is what makes it a test.

## 2026-09-20 - the firmware will say what it received

`MCU_EXT_CMD(FW_LOG_2_HOST) 0x13` times out on this part, but the log is not missing - it is in the
command space everything else that works here lives in. `FWLOG_2_HOST` is `0xc5` in the CE space and
the part reports it as `MCU_EVENT_DBG_MSG 0x27`, both of which mt76 already names. With the fallback
in `mt7615_mcu_fw_log_2_host()` the existing `fw_debug` knob turns it on:

    echo 1 > /sys/kernel/debug/ieee80211/phy*/mt76/fw_debug

It prints the firmware's own trace, including a line per command it receives -
`HEM: CMD_ID:0x03 SEQ:15 LEN:992 FID:528` - and the scan state machine's transitions. This is the
instrument the port has been missing: every earlier conclusion about whether the part acts on a
command rested on a timeout, and a command it answers but ignores looks exactly like one it carries
out.

First reading: through an association attempt on the plain driver the firmware logs the scan command
and then nothing at all, which is right - mac80211 sends nothing between the scan and the
authentication, because it hands a station to a driver with the older `sta_add` op only once that
station is authenticated.

The log is verbose enough to disturb what it measures. Level 2 floods; level 1 is silent. It is a
probe, not a setting.

### Resetting the part takes Bluetooth with it

The reset used for fast iteration - unbind and rebind `d0070000.sdio` - pulls the SDIO card out from
under `btmtksdio`, which shares the part on function 2. It wedges with its reference count at -1 and
floods the log with `Invalid bt type 0x80`, thousands of lines, which starved the capture and made
the box unreachable. `rmmod` cannot recover it; only a reboot can, and one soft reboot here took ten
minutes and the watchdog to come back.

`wifireset.sh` now takes `hci0` down and removes `btmtksdio` before the unbind and reloads it after.
With that: 24 BSSes on the first scan, no Bluetooth noise, `hci0` returns.

## 2026-09-20 - what the firmware says about the connection commands

With the log on, the part names every command it receives and what it did with it. The CE connection
path was captured through one association attempt.

### It receives them, and acts on them

    HEM: CMD_ID:0x1c SEQ:10 LEN:56          the channel privilege
    HEM: CMD_ID:0x12 SEQ:11 LEN:148         the bss, 116 bytes plus the 32-byte header
    BCM: -bcmConfigOpMode- [STATUS] BSS[1] (2407000 Hz/ Active/ Connect/Band 0)
    HEM: CMD_ID:0x13 SEQ:12 LEN:168         the station record
    pmUpdateBSSgroupTable add ucWTEntry 1, ucBssIndex 0

So `SET_BSS_INFO` and `UPDATE_STA_RECORD` are implemented here and change the part's state. The
lengths are what the driver sent, so the framing is right.

### The channel does not arrive

The driver prints what it put in the request and the firmware prints what it made of it:

    TRACE bss idx 0 band 1 ch 6 state 0 bssid 74:90:bc:12:33:90
    BCM: ... BSS[1] (2407000 Hz/ Active/ Connect/Band 0)

2407000 Hz is channel 0 on 2.4 GHz - the band arrived, the channel did not. `BSS[1]` is a bitmap of
active BSSes, not an index, and `Band 0` is the DBDC band, which is what was sent; only the channel
is wrong. Putting a different value in the byte after it, where `ucRfSco` sits, does not move the
frequency either, so the firmware reads `ucPrimaryChannel` from neither offset 70 nor 71 of the
request. Where it does read it is the open question.

### The ext station command is not inert

`EXT_CMD_ID:0x25` is implemented and acted on, which withdraws the earlier reading that the ext
commands are answered and ignored:

    cnmExtCmdStaRecUpdate: ucBssIndex 0, ucWlanIdx 31, u2TotalElementNum, 2
    cnmStaRecUpdated aucPeerMacAddr[74:90:bc:12:33:90]
    cnmStaRecMaualAssoc StaRec[48:00:00:1e:48:00]
    u4Wtbl = 1f, u4Ownmac = 48, u4Bw = 0, u4PfmuId = 48, ucAid = 21

It took the peer's address correctly and everything else as rubbish - own MAC index 0x48, AID 21, a
station record address that is not an address. That command was
`mt7615_mcu_sta_add(phy, vif, NULL, true)`, an experiment that asked for the interface's own record
with no station; it is removed. Shortly after it the firmware asserted:

    N9_ASSERT @ wifi_uni_mac_7668/mgmt/ar.c:6333

`ar.c` is the auto-rate module, which is where rubbish rates would land.

### Working the box while the log is on

The log is thousands of lines a second and the console cannot keep up: the box stops answering ssh
for minutes at a time. `echo 1 > /proc/sys/kernel/printk` across the capture fixes it. Polling
`dmesg` in a loop while it fills that fast takes minutes per pass, so the capture window is a fixed
sleep. And `pkill -f fwlog.sh` matches the ssh command running it and kills its own session.

### The frequency the firmware prints is not a readout

`bcmConfigOpMode`'s `2407000 Hz` looked like the part echoing back the channel it was given, so it
was used as an instrument to find which byte of the request the channel is read from. It is not one.
Five probes left it at 2407000: the channel as the driver header lays it out, a marker in the byte
after it, every byte of the RLM block carrying its own offset, the standalone
`SET_BSS_RLM_PARAM 0x19` payload ramped the same way, and the channel privilege asking for channel
11 instead of 6.

A field that never changes across all of those is not reporting the request. It is something the
firmware fills in elsewhere, most likely once a connection completes, and 2407000 is what it holds
until then.

What the line does prove is that the start of the structure is aligned: it prints Connect or
Disconnect according to `ucConnectionState` at offset 1, which is what the driver sends. And a
whole-struct ramp produces no line at all, so some field in the request is validated before the part
acts on it.

The instruments that do measure something here are the receive queue counter and association itself.

## 2026-09-20 - diffing against the vendor, and a transmit power table

### The descriptor is the shape the vendor builds

Dumped from inside `mt7615_mac_write_txwi()` for the authentication frame:

    3e 00 00 84  01 cc e0 06  0b 00 00 a0  00 58 00 00
    00 00 00 00  03 04 00 00  04 00 00 00  00 c0 0b 00

| Field        | Value | Meaning                                                    |
| ------------ | ----- | ---------------------------------------------------------- |
| DW0 tx_bytes | 62    | a 30-byte authentication plus the 32-byte descriptor       |
| DW0 p_idx    | 1     | the MCU port, which is gen4m's TC4                         |
| DW0 q_idx    | 1     | `MCU_Q1_INDEX`                                             |
| DW1 wlan_idx | 1     | the peer's table entry                                     |
| DW1 hdr_info | 12    | a 24-byte header, in units of two                          |
| DW1 hdr_fmt  | 2     | 802.11                                                     |
| DW1 pkt_fmt  | 2     | `TXD_PKT_FORMAT_COMMAND`                                   |
| DW1 own_mac  | 1     | the own-address index the part echoed as `OwnAddrHwID = 1` |
| DW5          | -     | transmit status to host, packet id 3                       |
| DW7          | 0x0b  | subtype 11, authentication                                 |

Every field is what `nicTxComposeDesc()` sets for a management frame, and the byte count matches a
well-formed authentication. So the descriptor is not the fault, and the frame is the right length.

What is not yet compared is the vendor's own descriptor bytes for the frame it sends and gets
acknowledged. gen4m's TX module logs them, so that is a direct diff rather than another guess.

### Diffing the descriptor against the vendor's, byte for byte

The vendor driver was rebuilt from `/root/gen4m` with a dump of `prTxDescBuffer` added to
`nicTxFillDesc()` for management frames, and its authentication captured while it associated. Both
descriptors, for the same frame to the same AP:

    vendor: 3e 00 0e 84  03 cc 00 06  0b 00 3d 80  10 f0 00 00
    mt76:   3e 00 00 84  01 cc e0 06  0b 00 00 a0  00 58 00 00

Five fields differed, all now matched:

| Field                     | Vendor | mt76 was | Why                                        |
| ------------------------- | ------ | -------- | ------------------------------------------ |
| `MT_TXD0_ETH_TYPE_OFFSET` | 14     | 0        | `(4 + 24) >> 1` - where the payload starts |
| `MT_TXD1_TID`             | 0      | 7        | mac80211 gives management frames VO        |
| `MT_TXD2_BA_DISABLE`      | 0      | 1        | set in two places, both needed a guard     |
| `MT_TXD2_MAX_TX_TIME`     | 61     | 0        |                                            |
| `MT_TXD3` bit 4           | 1      | 0        | the duration field is the part's to set    |
| `MT_TXD3_REM_TX_COUNT`    | 30     | 11       | the retry budget                           |

The ether-type offset is the structural one: gen4m computes it as
`(NIC_TX_PSE_HEADER_LENGTH + ucMacHeaderLength + ucLlcLength) >> 1`, and mt76 never sets it at all
because it does not need to on the parts it drives.

With all five matched the descriptor is identical to the vendor's but for the table index - 1 here,
3 there, which is only what each driver happened to allocate - and the authentication is still
unacknowledged. So the descriptor is no longer a variable. What differs now is what the table entry
behind that index holds, which `UPDATE_STA_RECORD 0x13` fills.

The transmit report changed with it: the first two attempts now come back `status 1` with a zero
count, rate, power and delay, which is not a frame that went out and failed but one that never went.
The third comes back `status 3` after the full thirty attempts.

### Diffing the payloads against the vendor's

A dump in `wlanSendSetQueryCmd()` gives every payload the working driver sends for a join, byte for
byte. **Every length matches the structures already written** - `0x11` 12, `0x17` 4, `0x12` 116,
`0x1c` 24, `0x13` 136, `0x19` 22 - so those layouts are confirmed on the wire rather than inferred.

What the bytes corrected:

- **`ucBMCWlanIndex` is 0xff**, not the last entry of the table as mt76 counts it. It appears in
  both `0x12` and `0x13`.
- **The bss before the join carries neither its name nor its address.** `ssid_len` is 0, the bssid
  is zero, `ucStaRecIdxOfAP` is 0xfe and the rate and phy sets are empty. Only the update after the
  association response carries `Sormy Net`, the bssid, `0x3fcf`/`0x000f` and phy set `0x13`.
- The station record also carries `ucRtsPolicy` 3, transmit and receive aggregation on, a block-ack
  window of 0x40 each way, and a maximum aggregate length of 0x0fff.
- `nss` is 2, not 1, and `short_preamble` is 0.

The constants guessed earlier are confirmed: `0x3fcf` operational, `0x000f` basic, `0x13` phy set,
`0x41` station type, band numbered from one, and the privilege asking for channel 6 with a 4000 ms
interval.

With all of that matched the authentication is still unacknowledged, but the transmit result changed
shape and now says something new: the first two attempts come back `status 1`,
`TX_RESULT_LIFE_TIMEOUT`, with a zero count, rate, power and delay - frames that expired in the
queue without being sent - and only the third goes to air, taking 140 ms and thirty attempts. The
vendor's own frames leave in 800 to 1800 microseconds. So the part is not transmitting promptly
after the join commands, which is a different fault from the one being chased.

### The command queue is not where management frames go

`TX_RESULT_LIFE_TIMEOUT` with a zero attempt count is a frame that sat in a queue until its life ran
out, so the queue was the next suspect. gen4m's resource table sends management frames out of TC4,
whose host queue is `HIF_TX_CPU_INDEX` - the command queue - where mt76 puts them on a data queue
with data credits.

Handing them to `dev->q_mcu[MT_MCUQ_WM]` instead made it worse: all three authentication attempts
came back `status 1` with nothing transmitted, where before the third at least reached the air. So
gen4m's HIF queue index does not map onto mt76's MCU queue, and the descriptor's port and queue
fields are what route the frame. Reverted.

Ruled out in the same pass: the grant event. gen4m's `EVENT_ID_CH_PRIVILEGE` is 0x10, which is
mt76's `MCU_EVENT_ROC`, so `mt7615_mcu_rx_unsolicited_event()` is already waiting on the right one
and the grant does arrive.

Still there, and worth removing on its own account: an ext `STA_REC_UPDATE 0x25` from the teardown
path, which this firmware turns into a station record at index 31 holding an address that is not an
address. It fires after the authentication has already failed, so it is not the cause, but a
firmware of this generation should not be given the tlv form at all.

### The part transmits nothing at all for this driver

The firmware prints a transmit count when it finishes a scan. The vendor driver's says `TxP:78`;
every scan under mt76 says `TxP:0`, including a directed one that has to be active:

    iw dev wlan0 scan ssid "Sormy Net"
    SCAN_STATE_SCAN_DONE eDbdcIdx 0, FW RxB:0 | FW RxP:0 | TxP:0

So the part sends no probe request, ever, and scanning here has only ever been passive - the results
come from beacons. That reframes the authentication failure: it is not the join sequence, not the
descriptor, and not the payloads, all of which now match the vendor byte for byte. The part does not
transmit for this driver at all.

It explains the rest in one go: the software scan returned nothing because no probe was sent, and
the authentication is never acknowledged because nothing radiates. The transmit report saying thirty
attempts at 22 dBm is what the firmware intends, not what leaves the antenna.

The scan state machine differs too - the vendor ends `DBDC SCN STATE_0: [5] -> [7]`, mt76 ends
`[6] -> [7]` on 24 of 26 scans - which is consistent with one running an active scan and the other a
passive one.

What to look at next is the initialisation, not the join: whatever the vendor sends between firmware
start and its first scan that turns the transmitter on. The same capture method applies, from boot
rather than from a join.

### Withdrawing "the part transmits nothing"

That reading came from one counter in the scan-done line, `TxP`, which is 78 for the vendor and 0
here. It does not carry the weight put on it: the same line reports `RxB:0 | RxP:0` for the vendor
on a scan that found the network, so those counters are not receive totals and `TxP` cannot be
assumed to be a transmit total either. The part also reports thirty transmit attempts at 22 dBm for
each authentication, which is not a part that transmits nothing.

What the difference does show is that the two drivers drive the scan differently, and that is worth
following on its own: the vendor's scan request is 250 bytes where mt76 sent 960. gen4m stops the
structure after the information elements; mt76 sends the whole of it, handing the part the fields
past them as zeroes. Trimming the request to `offsetof(ies) + ies_len` brings it to 322 bytes and is
kept - it is what the part's own driver does - but it did not change `TxP`, and the scan state
machine still ends `[6] -> [7]` where the vendor's ends `[5] -> [7]`.

The blocker as it actually stands: everything the driver sends now matches the vendor byte for byte,
the part attempts the frame, and the AP does not answer.

### The driver never sets a transmit power on this part

Dumping every command the vendor driver sends, from boot rather than from a join, shows an
initialisation mt76 does not do:

    cid=0x28 len=36     cid=0xed len=794    cid=0x0f len=324
    cid=0x49 len=568    cid=0x49 len=1288   cid=0x49 len=528
    cid=0x02 len=12     cid=0x70 len=284 (ten of them)
    cid=0xca len=328    cid=0xc4 len=264

`0x49` is `CMD_ID_SET_COUNTRY_POWER_LIMIT`, sent three times from `rlm_domain.c` with the
per-country transmit power tables. mt76 has no equivalent: its power path is
`mt7615_mcu_set_sku_en()`, which sends `MCU_EXT_CMD(TX_POWER_FEATURE_CTRL)` - and that command is in
this part's absent table, so the call returns success having sent nothing. **The driver configures
no transmit power at all.**

That is a hypothesis for the authentication failing, not a proven cause: the part still reports
`pwr 44` in its transmit report, which is 22 dBm, but that is the power the descriptor asks for
rather than evidence a table exists to permit it. It is the first initialisation difference found
that could plausibly stop a frame reaching the air while leaving receive working.

`SET_CHAN_DOMAIN 0x0f` is not the gap - mt76 does send that, from `mt7615_init_device()` and again
on a regulatory change.

Also unsent by mt76, and not yet looked at: `0x02` `CMD_ID_BASIC_CONFIG`, `0xca`
`CMD_ID_CHIP_CONFIG`, `0xc4` `CMD_ID_SW_DBG_CTRL`, ten of `0x70`, and a 794-byte ext command which
is the size of an efuse buffer upload.

### Giving the part a transmit power table

`CMD_ID_SET_COUNTRY_POWER_LIMIT 0x49` is now implemented. Its shape comes from gen4m's
`rlmDomainSendPwrLimitCmd()`: an eight-byte header of channel count, band and country code, followed
by forty bytes per channel - the channel number, three reserved, and thirty-six power values, one
per rate group, in half dBm. The part takes at most thirty-two channels per command, so a band goes
out in batches.

The observed lengths confirm the layout: the vendor sends 568, 1288 and 528 bytes of payload, which
is 8 + 14x40, 8 + 32x40 and 8 + 13x40. The port now sends 568 for 2.4 GHz and 1128 for the 5 GHz
channels mt76 knows about, and the part accepts both.

**It demonstrably takes effect**: the transmit report's power field moved from 44 to 42 - 22 dBm to
21 - which is the table being applied. Before this the part was never given a power at all, because
mt76 sets power through `MCU_EXT_CMD(TX_POWER_FEATURE_CTRL)` and `MCU_CE_CMD(SET_RATE_TX_POWER)`,
and both are in this firmware's absent list, so both calls returned success having sent nothing.

It did not fix the association. The authentication still ends `TX_RESULT_MPDU_ERROR` after thirty
attempts. So an empty power table was not the blocker - but the driver was genuinely not setting a
transmit power on this part, and now does.

## 2026-09-20 - the part transmits a host frame at last

Two things had to be true at once, which is why each looked useless on its own.

### The join, in the order the vendor driver sends it

Captured from the working driver with its own log on - below - and ported command for command:
`INDICATE_PM_BSS_ABORT 0x17`, `SET_BSS_INFO 0x12` **disconnected**, `BSS_ACTIVATE_CTRL 0x11`,
`CH_PRIVILEGE 0x1c`, `UPDATE_STA_RECORD 0x13`. The part now answers the way it answers the vendor:

    HEM: CMD_ID:0x11 SEQ:3 LEN:44
    Bss(0)(Active=1) OwnMac = 00:0c:43:26:60:48 NetType = 0 BMCIndex = 0 OwnAddrHwID = 1

which is the vendor's line exactly. The channel privilege is granted rather than timing out.

The capture, on the box, with the vendor driver's own debug:

    echo "0xff:0x00" > /proc/net/wlan/dbg_level
    for m in 0x0b 0x0d 0x0e 0x10 0x12 0x14 0x1f; do echo "$m:0x3f" > /proc/net/wlan/dbg_level; done
    iwpriv wlan0 driver "SET_FWLOG 0 2"

`Len` counts the 32-byte command header; the authentication goes out between 119 and 123.

| Seq | Command                          | Len | Payload | What the firmware said                  |
| --- | -------------------------------- | --- | ------- | --------------------------------------- |
| 110 | `BSS_ACTIVATE_CTRL 0x11`         | 44  | 12      | `Bss(0)(Active=1) OwnMac = <ours>`      |
| 111 | `SCAN_REQ_V2 0x03`               | 282 | 250     | `SCAN_STATE_SCAN_DONE`                  |
| 112 | `BSS_ACTIVATE_CTRL 0x11`         | 44  | 12      | `Bss(0)(Active=0) OwnMac = 00:00:...`   |
| 113 | `REMOVE_STA_RECORD 0x14`         | 36  | 4       |                                         |
| 114 | `INFRASTRUCTURE 0x09`            | 32  | 0       |                                         |
| 115 | `INDICATE_PM_BSS_ABORT 0x17`     | 36  | 4       |                                         |
| 116 | `SET_BSS_INFO 0x12`              | 148 | 116     | `ConnState[1]` - **disconnected**       |
| 117 | `REMOVE_STA_RECORD 0x14`         | 36  | 4       |                                         |
| 118 | `BSS_ACTIVATE_CTRL 0x11`         | 44  | 12      |                                         |
| 119 | `CH_PRIVILEGE 0x1c`              | 56  | 24      | `pmUpdateBSSgroupTable add ucWTEntry 3` |
| 120 | `UPDATE_STA_RECORD 0x13`         | 168 | 136     |                                         |
| 121 | `UPDATE_STA_RECORD 0x13`         | 168 | 136     |                                         |
| 122 | `UPDATE_STA_RECORD 0x13`         | 168 | 136     |                                         |
| 123 | `UPDATE_WMM_PARMS 0x1d`          | 76  | 44      |                                         |
| 124 | `SET_BSS_INFO 0x12`              | 148 | 116     | `ConnState[0]` - **connected**          |
| 125 | `UPDATE_STA_RECORD 0x13`         | 168 | 136     | `arIndicateSTAConnected, RCPI=130`      |
| 126 | `0x30`                           | 56  | 24      |                                         |
| 127 | `0xcb`                           | 68  | 36      | `Not handled CMD=0xcb`                  |
| 128 | `ADD_REMOVE_KEY 0x07`            | 96  | 64      |                                         |
| 129 | `ADD_REMOVE_KEY 0x07`            | 96  | 64      |                                         |
| 130 | `SET_RX_FILTER 0x0a`             | 100 | 68      | `RXM: u4RxFilter = 0xce70b`             |
| 131 | `INDICATE_PM_BSS_CONNECTED 0x16` | 44  | 12      |                                         |
| 132 | `SET_BSS_RLM_PARAM 0x19`         | 54  | 22      |                                         |
| 133 | `UPDATE_WMM_PARMS 0x1d`          | 76  | 44      |                                         |
| 134 | `CH_PRIVILEGE 0x1c`              | 56  | 24      |                                         |

The channel privilege, request type 0 (join), channel 6, band 1, `u4MaxInterval` 4000 ms:

    ChReq net=0 token=2 b=1 c=6 s=0 w=0
    00 02 00 06 00 01 00 04 00 00 00 00 a0 0f 00 00
    00 00 00 00 00 00 00 00

The station table after the keys, and the station record the firmware ends up with:

    #0 Used=1 BSSIdx=0 keyid=255 P=0 STA=254 Addr=00:0c:43:26:60:48
    #1 Used=1 BSSIdx=4 keyid=255 P=0 STA=254 Addr=02:0c:43:26:60:48
    #2 Used=1 BSSIdx=2 keyid=255 P=0 STA=254 Addr=06:0c:43:26:60:48
    #3 Used=1 BSSIdx=0 keyid=255 P=1 STA=0   Addr=74:90:bc:12:33:90

    STA_IDX[0] BSS_IDX[0] MAC[74:90:bc:12:33:90] TYPE[LEGACY AP] WTBL[3] USED[1] State[1]
    QoS[1] HT/VHT[1/0] AID[4] WMM[1] UAPSD[1] SEC[1]
    PhyTypeSet: BSS[0x13] Desired[0x13] NonHtBasic[0x01]
    RateSet: BssBasic[0x000f] Operational[0x3fcf] DesiredNonHT[0x3fcf]

The pairwise key, which the port sends field for field:

    Key Index : 0xc0000000      IS_TRANSMIT_KEY | IS_UNICAST_KEY, key id 0
    Key Length: 0x00000010      16
    Cipher    : 4               CIPHER_SUITE_CCMP
    Key RSC   : 00 00 00 00 00 00 00 00
    BSSID     : 74:90:bc:12:33:90

**`REMOVE_STA_RECORD 0x14` jams this firmware.** The vendor sends it twice before the join; sent
here it is acted on - `pmUpdateBSSgroupTable remove ucWTEntry 0` - and the part then stops
processing commands entirely. Every command after it is written to the bus, drains from the queue,
and is never seen again, with no error anywhere. Dropping it is what let the rest of the sequence
through. Why it is safe for the vendor and not here is not known; the station index it carries is
the obvious suspect.

**The broadcast entry is 0.** `BSS_ACTIVATE_CTRL` carries a broadcast wtbl index, and the vendor
sends 0 where the port was sending the interface's own wcid. The part echoes it back, so it is
checkable.

### The management frame descriptor

With the join state right, gen4m's descriptor for management frames finally does something: the MCU
port rather than the MAC, `TXD_PKT_FORMAT_COMMAND`, and no 32-byte appendix - mt76 writes one for
every frame. The part now reports the authentication sent:

    TRACE txdone wcid 3 status 0

That event had never appeared before. The same change measured on its own, before the join sequence
was right, changed nothing - which is why it was discarded once already.

The authentication is still unanswered, so what remains is the receive side or the frame's contents.

### The frame goes out and is never acknowledged

With the vendor's join sequence in place the part transmits, and its transmit report says what
happens:

    TRACE txdone status 3 widx 1 cnt 11 rate 0000 bw 0 pwr 44 delay 45088

Status 3 is `TX_RESULT_MPDU_ERROR`, and `cnt 11` is eleven attempts. Rate, bandwidth and power are
what the vendor's own report shows for the frame it sends and gets acknowledged - `RATE[0x0000]`,
`BW[20]`, `TxPwr[22dBm]` - so the frame leaves at the right rate and power and the AP does not
acknowledge it.

`EVENT_TX_DONE` is where all of this comes from, and it is worth reading properly: `ucPacketSeq`,
`ucStatus`, `u2SequenceNumber`, `ucWlanIndex`, `ucTxCount`, `u2TxRate`, then flags, tid, response
rate, rate table index, bandwidth, power and the transmit delay. mt76 has no case for that event and
drops it.

### Everything received is group-addressed

Across an association attempt the part hands up beacons and the AP's own broadcast data frames -
`fc 6208` and `4208` from `74:90:bc:12:33:90`, which are data, FromDS, protected - and **not one
frame addressed to this station**. So the radio is on the channel and hearing the AP well; what is
missing is unicast.

`SET_RX_FILTER 0x0a` is accepted and the part reports what it did with it:

    RXM: Before u4RxFilter = 0xcef1b, u4RxFilter1 = 0x1ff
    RXM: After  u4RxFilter = 0xcef1b, u4RxFilter1 = 0x1f0

The vendor ends up at `u4RxFilter = 0xce70b`, so two bits differ - 4 and 11. The command carries
`PARAM_PACKET_FILTER_*` bits rather than the register, so which of them moves those two is the next
thing to find.

## 2026-09-21 - the calibration window, and the transmit descriptor was never identical

### The efuse upload is 790 bytes, not 416

`wlanDownloadBufferBin()` uploads `uacEEPROMImage[u4EfuseStartAddress .. u4EfuseEndAddress]`, and
with `CFG_FW_Report_Efuse_Address == 1` that range comes from the firmware's own capability event
(`TAG_CAP_TX_EFUSEADDRESS`), not from the header's `EFUSE_CONTENT_BUFFER_START/END`. The captured
command is `cid=0xed len=794`, so the content is 790 bytes; the static constants describe 416.

Starting at `0x03a`, 790 bytes ends at `0x34f` - exactly the end of the last data block in
`EEPROM_MT7668.bin`, whose content runs to `0x389`. The port had been uploading `0x03a`-`0x1d9`,
leaving out the bytes at `0x1e2` and the sixteen at `0x340`.

Widened to 790. The firmware accepts it and the upload takes 5.78 s, which is the full-channel RF
calibration it runs on this command. **It did not fix the association.**

### The descriptor was not byte-identical - four fields differed

The earlier claim was wrong. Decoded against `mt7615/mac.h`, the vendor's authentication descriptor
and the port's differed in four places:

| DW  | Field        | Vendor | Port        |
| --- | ------------ | ------ | ----------- |
| 1   | `WLAN_IDX`   | 3      | 1           |
| 5   | TX status to | MCU    | host        |
| 6   | `FIXED_BW`   | 0      | 1           |
| 7   | `SUB_TYPE`   | 0      | 11 (`auth`) |

Matching DW6 and DW7 is harmless. Matching DW5 - asking the MCU rather than the host for the
transmit report - makes it **worse**: every frame then comes back `cnt 0`, never attempted, with two
reports instead of one. That one stays as mt76 has it.

With the rest matched the descriptor now reads byte for byte as the vendor's but for the packet id:

    3e 00 0e 84 03 cc 00 06 0b 00 3d 80 10 f0 00 00
    00 00 00 00 03 02 00 00 00 00 00 00 00 c0 00 00

### The frame itself is correct

Dumped alongside the descriptor: `fc 000b`, duration 0, DA and BSSID `74:90:bc:12:33:90`, SA
`00:0c:43:26:60:48`, algorithm 0, sequence 1, status 0. A valid open-system authentication frame, 30
bytes, exactly what the vendor sends.

### The payloads differed too

Dumping every CE payload and diffing against the vendor's:

| Command | Field                    | Vendor | Port |
| ------- | ------------------------ | ------ | ---- |
| `0x13`  | `ucStaIndex`             | 0      | wcid |
| `0x1c`  | `ucTokenID`              | 1      | 0    |
| `0x12`  | `rlm.nss`, `nss`         | 2      | 1    |
| `0x12`  | `wmm_set`                | 2      | 0    |
| `0x12`  | pre-join short slot/pre. | 0      | 1    |

All matched to the vendor. **None of it fixed the association.**

### The power table was asking for more than the part is calibrated for

The firmware answers the `0x49` table with 935 lines of
`Invalid VHT20 6 TxPwrLimit 40 + FeLoss 2 (must <= efuse=34) of ch 6` - the regulatory domain offers
20 dBm, the part's own efuse permits 17. `mt7615_init_txpower()` is meant to clamp `max_power` to
the EEPROM's target power and evidently does not for this layout.

Capping every entry at 10 dBm makes the reported transmit power follow it - `pwr 22` instead of
`pwr 42` - and cuts the rejections to 162. The authentication still ends `MPDU_ERROR` after thirty
attempts. **Transmit power is not the blocker**: it fails identically at 11 dBm and at 21 dBm with
the AP at -33 dBm.

### Receive is not dropping anything

Two probes: a trace of every frame `mt7615_mac_fill_rx()` rejects, and a trace of every frame not
addressed to a group address, both uncapped.

- frames dropped in `fill_rx`: **0**
- unicast frames handed up across a whole join attempt: **0**, of 43 total

Setting `PARAM_PACKET_FILTER_PROMISCUOUS` in the `0x0a` filter changes neither number. The part
hands up beacons and nothing else, and the receive path loses none of what it is given.

### What the firmware says, and what it does not

Its reaction to every join command is line for line the vendor's -
`Bss(0)(Active=1) OwnMac = 00:0c:43:26:60:48 NetType = 0 BMCIndex = 0 OwnAddrHwID = 1 TsdHwId = 1`,
then `pmUpdateBSSgroupTable add ucWTEntry 3, ucBssIndex 0`, identical on both sides.

The one number that differs is in the scan-done line: the vendor reports `TxP:78`, the port `TxP:0`.
That is the firmware's own count of probe requests transmitted, for frames it generates itself with
no descriptor from the host, on a scan both drivers ask for actively.

The ext `STA_REC_UPDATE 0x25` does write a station record of its own invention -
`cnmStaRecMaualAssoc StaRec[48:00:00:1e:48:00]`, `u4Wtbl = 1f`, `StaRec 31 InUse` - but only during
teardown, so it is not corrupting the join. It is suppressed now along with ext `BSS_INFO_UPDATE`
and `DEV_INFO_UPDATE`, since the CE commands replace all three. No effect either.

### Still unsent from the vendor's initialisation

`0x02` `BASIC_CONFIG` (12 bytes, checksum-offload and debug flags - not RF), ten of `0x70`
`GET_SET_CUSTOMER_CFG` (the `wifi.cfg` keys as strings), `0xca` `CHIP_CONFIG` (328 bytes) and `0xc4`
`SW_DBG_CTRL` (264 bytes). `0x28` `SET_DBDC_PARMS` and the 790-byte efuse upload are now sent.

`wifi.cfg` names two settings the port does not carry: `CalTimingCtrl 1`, which makes the vendor's
efuse command `ucCmdType = 0x11` rather than `0x01` and defers calibration instead of sweeping every
channel at power-on, and `SetChip0 KeepFullPwr 1`, which is `CMD_ID_KEEP_FULL_PWR 0x2a`. Both were
implemented; the box went off the network during that build, before the modules were installed, so
neither has been measured.

## 2026-09-21 - reading the vendor's transmit path instead of probing it

Two real defects, both found by reading gen4m against mt76 rather than by testing.

### The SDIO transmit quota: a wrong fix, and the measurement that killed it

`nicTxProcessMngPacket()` pins every MMPDU to TC4, and `arTcResourceControl[TC4]` is
`{PORT_INDEX_MCU, MCU_Q1_INDEX, HIF_TX_CPU_INDEX}`, so the vendor charges management frames to the
CPU-port pool. mt76 picks the pool from the queue instead - `bool mcu = q == dev->q_mcu[MT_MCUQ_WM]`

- so a management frame carrying `PORT_INDEX_MCU` was charged to the data pools.

That looked like a leak, on the assumption that the part credits the pages back to the pool the
descriptor named. **It does not.** Tracing all sixteen counts in `mt76s_refill_sched_quota()`:

    TRACE wtqcr 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

Queue 0 and nothing else, on every single refill - which is what gen4m says in as many words, in the
comment on why it sends init commands on TC0: _"SDIO HW always reports CPU's TXQ_CNT at TXQ0_CNT in
CR4 architecutre"_.

mt76 maps queue 0 to the BE **data** pool, so management frames on the data pool were being
replenished all along. Charging them to `pse_mcu_quota` instead made it worse: that pool is read
from `mcu_txq`, which this port sets to 15, and queue 15 is never credited - so it ran off its
initial seed alone and the join stalled at `mcu quota 0` with commands backing up. Reverted.

What the measurement leaves behind is a real latent defect: with `mcu_txq = 15` the MCU pool is
seeded once by `mt7663s_mcu_init_sched()` and never refilled, so a long enough run of commands
starves it. Setting it to 0 is not the fix either, because mt76 already counts queue 0 as BE data
credit and would then count it twice. Not resolved; the pool is large enough that nothing has hit
it.

### `REMOVE_STA_RECORD` was the wrong operation, and it does not jam anything

`ENUM_STA_REC_CMD_ACTION_T` is `STA_REC_CMD_ACTION_STA = 0` (the one station named),
`STA_REC_CMD_ACTION_BSS = 1` (every station record of the bss), `BSS_EXCLUDE_STA = 2`.
`cnmStaFreeAllStaByNetwork()` sends action 1 as a clean slate, and that is what the vendor's two
pre-authentication `0x14`s are. The port sent action 0 with a station index - a different operation.

Sending the vendor's form, twice, in the vendor's positions: the join runs through every step
normally. **The earlier note that `0x14` jams this firmware is withdrawn** - it dates from before
the `MT_CHFREQ` read was removed, when one blocking register read was cascading timeouts onto every
command behind it.

### Read and eliminated, without a test

- **A separate SDIO port for management frames.** `HAL_WRITE_TX_PORT` always writes `MCR_WTDR1`,
  exactly as mt76 does. The TC is resource accounting, nothing else.
- **An unserviced receive port.** gen4m has two (`MCR_WRDR0`, `MCR_WRDR1`); mt76 services both, on
  `WHIER_RX0_DONE_INT_EN` and `WHIER_RX1_DONE_INT_EN`.
- **The part asleep in firmware-own when the frame goes out.** `pm->enable` is set only from debugfs
  and is zero otherwise, so `mt76_connac_power_save_sched()` returns immediately.
- **The hardware own-address slot.** `ucOwnMacIdx = (eNetworkType == NETWORK_TYPE_MBSS) ? 0 : 1` -
  slot 0 is reserved for MBSS, so a station BSS takes slot 1 by design. The port sends 1 and the
  firmware reports `OwnAddrHwID = 1` for both drivers.

### The transmit power table was reading the wrong source

`chan->max_power` is already clamped by `mt7615_init_txpower()` against a target read out of the
EEPROM at offsets this part does not use: it asked for 20 dBm on 2.4 GHz where the efuse permits 17,
and for 3.5 dBm on 5 GHz. The vendor sends the regulatory limit and lets the firmware clamp against
its own calibration, which is what the 935 lines of
`Invalid ... TxPwrLimit 40 + FeLoss 2 (must <= efuse=34)` are.

Taking `chan->max_reg_power` instead gives `pwr 44` on 2.4 GHz - 22 dBm, the vendor's exact
operating point - and `pwr 39` on 5 GHz instead of `pwr 9`.

Association fails identically at 11 dBm, 17 dBm and 22 dBm, so transmit power is not the cause. 5
GHz fails the same way as 2.4 GHz.

### Where that leaves it

Everything the host controls now matches the working driver: the initialisation commands, the join
sequence command for command, every payload byte, the transmit descriptor, the frame, the transmit
power, the queue accounting. The firmware's own log reports the same thing for both drivers at every
step. The part still reports thirty unanswered attempts, and still hands up no unicast frame from
anyone.

## 2026-09-21 - the scan request, field by field, and a trap in the harness

### `TxP` is not a usable signal

`CMD_SCAN_REQ_V2_T` and `mt76_connac_hw_scan_req` have the same layout through offset 226, where
both drivers end the request - gen4m at `OFFSET_OF(aucIE) + u2IELen`, the port at the same
expression. Everything after that, `ucScnCtrlFlag` and the per-channel control arrays, neither one
sends.

Reading `scnSendScanReqV2()` against `mt76_connac_mcu_hw_scan()` for a wildcard scan, which is what
both were doing:

| Field           | gen4m                                | mt76                           |
| --------------- | ------------------------------------ | ------------------------------ |
| `ucScanType`    | `SCAN_TYPE_ACTIVE_SCAN` = 1          | 1                              |
| `ucSSIDType`    | `SCAN_REQ_SSID_WILDCARD` = `BIT(0)`  | `BIT(0)`                       |
| `ucSSIDNum`     | 0                                    | 0                              |
| `ucNumProbeReq` | never assigned, so 0 from the memset | 2                              |
| `ucChannelType` | `SCAN_CHANNEL_SPECIFIED` = 4         | 4                              |
| bytes 6-7       | `aucReserved[2]`                     | `scan_func`, `version`, both 0 |

Only `ucNumProbeReq` differed. Set to 0 for this firmware, as its own driver leaves it: `TxP` is
still 0.

So the request is the vendor's, field for field, and the counter still reads zero where the vendor's
read 78. **`TxP` is not evidence** - which fits the other two counters on that line, `RxB` and
`RxP`, reading zero for the vendor on a scan that found the network.

### Do not insmod the vendor driver and leave it resident

`blacklist` stops a module being pulled in by its alias; it does not stop one already loaded from
registering as an SDIO driver. Loading `wlan_mt76x8_sdio` by hand for a capture leaves it resident,
and from then on it wins the race for function 1 on every MMC rebind - its probe fails, `mt7663s`
gets `-EBUSY`, and the function is left bound to nothing with no `wlan0` at all.

Remove it before rebinding. `install wlan_mt76x8_sdio /bin/false` in `/etc/modprobe.d` holds it off
during a swap, but take that back out afterwards or the vendor fallback silently stops working.

## 2026-09-21 - probing the association blocker, fast

Module parameters in place of rebuilds, so a try costs about 25 s on the box: `ce_rx_filter`,
`ce_tx_rate`, `ce_mgmt_as_cmd`, `ce_bss_connected`.

### Eliminated

| Idea                            | Tried                                              | Result                         |
| ------------------------------- | -------------------------------------------------- | ------------------------------ |
| the rx filter's value           | `0x0f 0x8f 0x2f 0xaf 0x01 0xffffffff`              | identical, no unicast ever     |
| the transmit rate               | CCK 1M, CCK 11M, OFDM 24M, part's own choice       | identical, `cnt 30` unanswered |
| the descriptor style            | `mgmt_as_cmd` on and off                           | identical                      |
| the bss being connected first   | `conn_state` 0 instead of 1 before the auth        | identical                      |
| the answer arriving as an event | trace on every unhandled event id                  | none arrive                    |
| the part's own drop counters    | `CMD_SW_DBG_CTRL 0xc4`, queried as its driver does | 264 bytes of zeroes            |
| monitor mode as an instrument   | `iw set type monitor` + `set freq`                 | receives nothing: see below    |

**`SET_RX_FILTER 0x0a` is not a filter.** Drop it from the join and the part transmits _nothing_ -
all three attempts come back `cnt 0`. Its value makes no difference at all, so what matters is that
the command is sent, not what it says.

**Monitor mode cannot be used here.** `MCU_EXT_CMD_CHANNEL_SWITCH` is absent, so `iw set freq` sets
nothing and the radio stays wherever the last scan or channel grant left it. Outside a join there is
no way to tune it.

**`UPDATE_WMM_PARMS 0x1d` wedges the firmware** when sent before the authentication - the join stops
at that command. It cannot be the blocker either way: its own driver sends it at step 123, after the
authentication and association have already succeeded.

**`GET_SET_CUSTOMER_CFG 0x70` wedges the whole chip.** Sent at init with the `wifi.cfg` settings as
text, four to a command in `CMD_FORMAT_V1_T` shape, it leaves Bluetooth on function 2 flooding
`Invalid bt type 0x80`. Removed.

### Where that leaves the transmit side

Every variable the host controls has now been matched to the working driver or swept: the
initialisation commands, the join sequence, every payload byte, the descriptor, the frame, the rate,
the power, the queue accounting, the spatial-extension index. The part reports thirty attempts at 22
dBm on the granted channel and the AP never answers.

The absence of unicast receive is fully explained by that: a station filter drops other-BSS unicast,
so the only unicast that should ever arrive is the AP's answer, and there is none to arrive. The two
halves are one fault, not two.

## 2026-09-21 - the channel grant arrives late, and two of my own claims were wrong

### The grant times out, and that was aborting the join

`mt7615_mcu_ce_privilege()` waited one second for the channel grant. The part takes longer. Logging
the event shows it arrives correct and complete, after the wait has already given up:

    TRACE join privilege -> -110
    TRACE grant bss 0 token 1 status 0 chan 6 band 1 width 0 seg1 0 type 0 dbdc 0 for 4000

`STEP()` returns on error, so the whole join was abandoned there and mac80211 reported
`failed to insert STA entry for the AP (error -110)`. When the grant happened to arrive inside the
second, the join went ahead but the authentication then raced the 4000 ms grant.

Waiting five seconds instead. **Measured**: the `-110` aborts are gone, and all three authentication
attempts now transmit - `cnt 30` each - where before the second and third came back `LIFE_TIMEOUT`
with a zero count.

### Two earlier claims withdrawn

**`SET_RX_FILTER 0x0a` is not required for the part to transmit.** With the command dropped entirely
the part still attempts the frame thirty times. The run that suggested otherwise had simply not
reached the authentication. Its value has no effect either, swept across six values including
`0xffffffff`.

**The `LIFE_TIMEOUT` reports were the missing channel grant**, not later frames expiring behind the
first one's retries. They disappear once the grant is waited for properly.

### Beacons stopping is not evidence of being off channel

The target AP's beacons stop about two seconds before the join begins - that is wpa_supplicant's
scan hopping channels - and do not come back because `u4RxFilter` has `DROP_OTHER_BEACON` set while
no BSSID is configured. The vendor's filter reads `0xce70b` at the same point, with that bit clear,
which is why its log shows beacons throughout.

The receiver is demonstrably live and on a 2.4 GHz channel during the authentication: a frame from a
neighbouring AP arrives between the second and third attempt.

### Also eliminated

- **A blocked MAC.** The AP could have been refusing a station that had failed hundreds of
  authentications. With `02:0c:43:26:60:77` it fails identically.
- **The calibration window.** Start 0 or `0x03a`, length 416, 790 or 1024: no combination changes
  anything.

### Registers cannot be read, and the MAC setup changes nothing

`mt76_rr()` goes through `MCU_CE_CMD(REG_READ) 0xc0` here. The command is sent and the part
answers - `HEM: CMD_ID:0xc0` appears in its log - but every read comes back zero, including the chip
identity:

    0x80000000  0x00000000     MT_HW_REV
    0x80000008  0x00000000     MT_HW_CHIPID
    0x820f5030  0x00000000     MT_CHFREQ(0)
    0x820fd098  0x00000000     MT_MIB_SDR36(0), transmit airtime

So the register space is not an instrument on this part, and `MT_CHFREQ` reading zero was real
rather than a timeout artefact. The transmit-airtime counter, which would have said outright whether
the MAC keys up, is unreadable with it.

Reads returning zero does not mean writes are ignored, so `mt7615_mac_init()` and
`mt7615_phy_init()` were tried rather than skipped - they program the TMAC, aggregation and
protection registers, and an unconfigured MAC would fit the symptom. No difference.

## 2026-09-21 - the reload, and a comparison that was not one

### A filter difference I had been citing is not a difference

The `u4RxFilter` values compared here - `0xcef1b` for the port against `0xce70b` for the vendor -
were not taken at the same moment. The vendor's line is at 183.838, after its association completed
at 183.812; ours is from before the authentication. The vendor's pre-authentication value was never
captured, so there is nothing to compare and bits 4 and 11 prove nothing.

### The reload gets past the patch semaphore and stops at the CR4

Powering the firmware down on unload, and handing ownership back afterwards as
`halHifPowerOffWifi()` does, is now in place: `NIC_POWER_CTRL`, wait for `WCIR_WLAN_READY` to clear,
then `set_fw_ctrl`. A warm reload now downloads the N9 and starts it, where before it could not take
the patch semaphore at all.

It then stops at the next step, every time:

    mediatek/WIFI_RAM_CODE_MT7668.bin Version: mp2_1801__
    mediatek/WIFI_RAM_CODE2_SDIO_MT7668.bin Version: trp1000800
    Message 00000001 (seq 7) timeout
    mediatek/WIFI_RAM_CODE2_SDIO_MT7668.bin section 0 download request failed
    MCU init failed: -110

Twenty seconds is the full MCU timeout, so the N9 answers its own start command and then never
answers the CR4's download request. Not a short timeout, and not a settling problem: a two-second
delay between the start and the request changes nothing.

**The one state difference left at that point is the ROM patch.** A warm part still holds it, so
`mt7615_load_patch()` gets `PATCH_IS_DL` and skips - there is no `HW/SW Version` line in a warm
load's log, where a cold one has it. Whether the download service the CR4 request needs comes with a
freshly downloaded patch is the next thing to find out.

## 2026-09-21 - mainline mt76 associates

Both bands, repeatably, and it passes traffic.

    state=COMPLETED after 2.5s
    Connected to 74:90:bc:12:33:90 (on wlan0)
            SSID: Sormy Net
            freq: 2437.0
            signal: -45 dBm
            tx bitrate: 300.0 MBit/s

    20 packets transmitted, 20 received, 0% packet loss
    rtt min/avg/max/mdev = 1.438/13.652/31.526/7.553 ms

5 GHz associates on channel 40 at 866.5 Mbit/s, -39 dBm.

### What is not yet known

**Which change did it.** The build script reported failures only on a lowercase `error:`, while make
prints `Error 1`, so several builds failed silently and left the previous module in place - the runs
recorded against them were against stale code. The script now checks the built object exists.

Of the changes between the last build that did compile and the working one, the firmware-ownership
handback was ruled out directly: removing it, the part still associates. The channel-grant wait is
the remaining candidate and is tested separately below.

### Throughput

`iperf3`, six seconds each way, wlan0 given its own address and routing table. The host is itself on
Wi-Fi, so these are not comparable with the vendor figures in `board.md`, which were taken to a
wired host - and on 5 GHz the host shares the band, so the box's transmit contends with it directly.

| Band          | Link rate        | TX   | RX  |
| ------------- | ---------------- | ---- | --- |
| 2.4 GHz, ch 6 | 300 Mbit/s HT40  | 94.8 | 111 |
| 5 GHz, ch 40  | 866 Mbit/s VHT80 | 73.5 | 144 |

The 2.4 GHz figures are above the vendor's recorded 83 and 91, which were measured over a better
path, so there is no gap there. 5 GHz receive matches the vendor's 141. 5 GHz transmit is the one
number a shared-band host cannot measure.

## 2026-09-21 - consolidating the patch set

Eight patches: six generic mt76 fixes, the MT7668S itself, and the DKMS build. The CE command space
was a separate patch while it did not work; it is folded into the MT7668S patch now, because the two
touched nine of the same files and the driver in between could scan but not associate - a bisect
hazard for no gain.

### Everything the part needs is one profile

`mt7615_fw_features` now carries the firmware images, the patch address, the EEPROM name and
calibration window, the absent command lists and the protocol flags. `mt7663s_probe()` selects it
from the chip id, and nothing below asks again: `is_mt7668()` is gone from `mcu.c` and `eeprom.c`,
along with the `MT7668_*` defines and the `case 0x7668:` in `mt7615_mcu_set_eeprom()`. Symbols named
after the part - `mt7668_load_ram`, `mt7668_fw_tailer` - are named after what they do instead.

A part that answers the same commands needs a second profile entry and nothing else.

### Review pass

- The CE command space is its own file, `mt7615/mcu_ce.c`.
- Three `EXPORT_SYMBOL_GPL` removed: every caller is in the same module.
- `mt7615_mcu_ce_set_power()` has no caller outside its file, so it is static.
- Two unused includes dropped; the command-queue drain bound named rather than a literal 50.
- No `TRACE`, probe, or module parameter survives anywhere in the set.

### Two mistakes in the harness, both fixed

The build script grepped for a lowercase `error:` while make prints `Error 1`, so failed builds left
the previous module installed and several results were recorded against stale code. It now checks
the built object exists.

The patch generator diffed the working tree against a baseline that still had the patch applied, so
it produced a patch of nothing. Both patches are now regenerated by a script that moves them aside
first and refuses unless the result reproduces the tree.

### One source of truth for the firmware profile

The profile refactor had been left half-applied: `mt7615_apply_fw_features()` stored the profile
pointer and then copied two of its fields into `dev->fw_owns_mac` and `dev->fw_ce_join`. Twenty-two
sites read the mirrors and six read the profile behind a `dev->fw &&` guard, so the same fact had
two spellings and a reviewer would have to check they agreed.

`dev->fw` is now never null: `mt7615_fw_features_default` is an empty profile assigned in all three
bus probes next to `dev->ops`, and the SDIO probe overwrites it for a part that has its own. The
mirrors and every null guard are gone.

The default cannot be assigned in `mt7615_init_device()`, which looks like the natural place: on
SDIO the firmware load runs from `mt7663s_init_work()` before the device is registered, and it reads
`dev->fw->rom_patch`.

### Dead code from withdrawn hypotheses

`mt7615_mcu_ce_rx_filter()` had no caller left once `SET_RX_FILTER` was dropped from the join
sequence - a static function the compiler would have warned about. Removed, and the comment it left
behind on `mt7615_mcu_ce_activate()`.

The station-state enum was annotated `authenticating` and `associated`. The vendor's `mac.h` gives
`STA_STATE_1/2/3` as 0/1/2 by the 802.11 frame classes the part accepts, which is what the comments
now say. The values were already right.

Patch 0007 is 2043 lines over 20 files. Unbuilt: the box has been unreachable since the vendor bench
attempt, so the profile collapse and both cleanups are source-verified only.

### The tx path spelled its rule twice

Whether a frame goes to the part as a command decides both the descriptor size written in
`mt7615_mac_write_txwi()` and the headroom pushed in `mt7663_usb_sdio_write_txwi()`. Each computed
`ce_join && !ieee80211_is_data()` for itself. The two must agree or a management frame is written
with one size and pushed with another, so the rule is now `mt7615_mgmt_as_cmd()` and both call it.

`MT7615_CE_PSE_HDR_LEN`, `MT7615_CE_MAX_TX_TIME` and `MT7615_CE_TX_COUNT` were defined in the middle
of a function body and never undefined, so they leaked to the rest of the file regardless. They are
at file scope with the other constants.

### What took the box off the network

`vbench.sh` printed `loaded: mt7663s` after its rebind and the ssh session died on the next line.
The vendor module never loaded - the `sed` that flips the blacklist did not take - so whatever
happened, happened with mt76 loaded, not with the vendor driver.

The script's sequence is `rmmod` the stack, unbind `d0070000.sdio`, rebind, reload: the warm reload
path, which is the first open item in the mainline gap and is known to fail its CR4 download. That
is the prime suspect and it is not one of the hangs closed earlier - those were `0x1d` and `0x70`
wedging the firmware and `MT_CHFREQ` cascading timeouts.

ssh reaches this board over a USB Ethernet adapter, not over `wlan0` - no Ethernet connector is
fitted, but one is plugged in. That link went down with the rest of the box, so the teardown did not
merely cut Wi-Fi: the host stopped. Nothing answered ICMP or TCP on any address, and the watchdog
did not bring it back.

A warm reload can therefore take the whole board down, which makes the reload bug worse than an
inconvenience.

`vbench.sh` also rewrites `/etc/modprobe.d/zz-h96max-m20-combo.conf`, and its `restore()` runs only
when the script is called with that argument, so a normal run leaves the edit in place. `resume.sh`
puts the config back before anything else.

### The tree could not have built

Reading `mcu.c` for anything to cut turned up two `static int mt7615_load_ram` at file scope: the
original one-argument mt7615 loader, and the three-argument loader the rename pass had renamed onto
it from `mt7668_load_ram`. Nothing guarded either, so the file was a redefinition error. The
three-argument one is `mt7615_load_ram_image()` now, named for downloading one image rather than for
a part.

Six functions in `mac.c` had their `owns_mac` guard placed above the declarations that were already
there, which `-Wdeclaration-after-statement` rejects. The guard sits below the declaration block in
all of them now.

Neither would have survived a build. Nothing has been compiled since the rename pass, so both sat in
the tree unnoticed while the patch was otherwise being polished - the patch reproducing the tree
says nothing about whether the tree compiles.

### Comments swept, and the set put through checkpatch

The comments had never been read as a set. One described the probe knobs that were removed and had
been sitting above `to_rssi()` describing nothing. Four others were narrative rather than a reason -
"what a firmware carries and what it answers to", "the join is worthless without the channel" - and
say what they are for in one line now. The field trailers on `mt7615_fw_features` and the enum
comments stay: those carry what a name cannot.

`checkpatch.pl --strict` had never been run. It found one error and seven warnings: a struct defined
and a pointer declared in the same statement, the `STEP()` join macro (a macro with a `return` in
it), unnecessary braces, and five commit descriptions wrapped at 80 rather than 75. The macro is
gone - `mt7615_mcu_ce_send()` reports the failing command id instead, which covers every CE command
rather than the eleven join steps. Fourteen strict-mode checks followed, all blank lines and one
alignment.

Two of those were layering mistakes rather than style. The brace fix belonged in 0004, which
introduces that code, not in 0007 reverting it; and 0004 was adding two blank lines to
`struct mt76_mcu` that only 0007 fills. Removing them shifted `mt76.h` under 0006, whose hunk then
applied with fuzz - which on macOS is silent apart from a `.orig` left behind.

The set now applies to a pristine tree with no fuzz and no rejects, reproduces the working tree, and
is clean under `--strict`. 0007 is 1996 lines.

## 2026-09-21 - the tree builds, and the bench against the vendor

The first compile since the rename pass failed on one error: `mt7615_mcu_ce_band_power()` fell off
the end of a non-void function. Removing the `STEP()` macro had used a replace-first on
`return ret;`, which matched that function rather than the join. `-Werror=return-type` caught it.
With `return 0;` restored the whole set builds.

Everything else in the tree was already correct: the duplicate `mt7615_load_ram`, the six
`-Wdeclaration-after-statement` guards and the `mcu_ce` rename all compiled as written.

On a cold boot the new module claims func 1, loads both firmware images and brings up `wlan0` with
nothing in the log but the two version banners. 2.4 GHz associates in 2.5 s at -44 dBm, 5 GHz in 2 s
at -39 dBm and 866.5 Mbit/s.

Benched against a wired host, the same path as the vendor rows in `board.md`:

| Band   | mt76 TX | mt76 RX | vendor TX | vendor RX |
| ------ | ------- | ------- | --------- | --------- |
| 2.4GHz | 60      | 90.5    | 83        | 91        |
| 5GHz   | 148     | 151     | 154       | 141       |

5 GHz matches in both directions. 2.4 GHz receive matches. 2.4 GHz transmit does not - 60 against
83, three runs at 59.9, 59.1 and 63.0 - and the rate reads 104 Mbit/s while transmitting rather than
the 144 the link negotiated. That is now the third ranked item.

The earlier 2.4 GHz figures of 94.8/111 were measured to a host on Wi-Fi and are withdrawn; that
path flattered transmit. The same correction doubles the 5 GHz transmit figure, from 73.5 to 148,
because the measuring host was sharing the band.

### Reaching the box

`ssh h96max-m20` resolves to an IPv6 link-local address after a reboot and hangs there while IPv4
port 22 is open. `192.168.1.152` works. `mmc` numbering moved from `mmc2` to `mmc1` across the
reboot, as it is documented to do.

A soft reboot is fine - the box came back on its own. It is the warm `rmmod` and rebind that is
unsafe, not `reboot`.

### The 2.4 GHz gap was not real

Three consecutive transmit runs read 59-63 Mbit/s against the vendor's 83, with the link rate at 104
rather than 144, and that went into `board.md` and the ranked list as a performance gap. It does not
hold. Six runs on a fresh boot read 85.2, 88.0, 86.6, 86.9, 87.7 and 88.6 - at or above the vendor -
with the rate steady at 144.

Two explanations were tested and both failed: a fresh boot reproduces the high figures, and
switching 5 GHz to 2.4 GHz and back does not bring the low ones back. What is left is the band
itself. Three samples in one sitting, with no control and a vendor figure from a different day, were
not enough to publish a gap from.

### The eFUSE is not readable through mt76's register path

`mt7615_efuse_read()` returns success with sixteen zero bytes, and `MT_EFUSE_BASE_CTRL` reads
`00000000`, so the EMPTY bit cannot be trusted either - the window is not reachable over SDIO. The
profile comment was right.

The vendor reaches the eFUSE through the firmware, not these registers: its strings carry
`CMD_ID_ACCESS_EEPROM`, and `wifi.cfg` has `CFG_FW_Report_Efuse_Address`. mt76 in this tree has only
`MCU_EXT_CMD(EFUSE_BUFFER_MODE)`, which sends the blob and cannot read back. Taking the unit's own
address from the chip therefore needs a new command, not a flag.

### Both drivers do not read firmware from the same place

`payload.list` installs everything under `/lib/firmware/mediatek/`, which is where mt76 asks for it
and where linux-firmware puts MediaTek files. gen4m calls `request_firmware()` with bare names built
from `CFG_FW_FILENAME`, `CFG_CR4_FW_FILENAME` and `CFG_EEPRM_FILENAME` plus one `snprintf` for the
patch, so it looks in `/lib/firmware/` and finds nothing the repo ships. The flat copies on this box
are debris from the vendor experiments.

Prefixing those three defines and the patch format with `mediatek/` is the whole change - the four
name variants gen4m builds all derive from them, and 64 bytes is enough for the longest name with
the prefix.

### The efuse command is a backport; the ordering is the work

`MCU_EXT_CMD_EFUSE_ACCESS` is 0x01 in mt76 and `EXT_CMD_ID_EFUSE_ACCESS` is 0x01 in the vendor tree,
and the vendor's `CMD_ACCESS_EFUSE_T` is the `{__le32 addr; __le32 valid; u8 data[16]}` mt76 already
uses for mt7915. `mt7615_mcu_get_efuse()` is that reader, block-aligned, checking `valid` and the
returned length.

Calling it from `mt7615_eeprom_init()` oopsed in `mt76_mcu_send_and_get_msg()`. That function runs
in probe, before the firmware is downloaded - the file-based eeprom path works there only because
`request_firmware()` needs no MCU. `docs/todo/h96max-m20-wifi-mac.md` already said this in words;
the crash was the cost of not reading it first.

The vendor starts its firmware at `gl_init.c:2396` and registers the netdev at `2535`. mt7921 has
the same shape - `mt792x_mcu_init()` inside `mt7921_init_hardware()`, `mt76_register_device()` after
it. The mt7615 SDIO path registers first and downloads afterwards, which is the whole difference.

`MT76_MCU_CMD_ABSENT` now returns `-ENOENT` rather than success when the caller passed a `ret_skb`.
This command would have been the first to dereference the null it used to hand back.

### Three reboots stranded the board

Testing a driver change costs a reboot because the warm reload does not work, and the third one did
not come back - no ping, no ssh. `docs/watchdog.md` gives the mechanism. The reload item is not a
convenience: it is what forces a power cycle per iteration, and each one is a chance to need
physical access. It belongs first for that reason alone.

## 2026-09-22 - the per-unit address, and what the newer firmware does not fix

### wlan0 takes the chip's own address

`wlan0` comes up as `d0:aa:5f:32:eb:f2` instead of the calibration blob's `00:0c:43:26:60:48`, with
the blob's calibration otherwise intact. Both bands associate as before - 2.4 GHz in 2 s at -44 dBm,
5 GHz at 866.5 Mbit/s VHT80 - and the log carries nothing.

Four gates had to be satisfied in order, each found by driving into it:

1. `mt7615_eeprom_init()` runs in probe, where no MCU exists. Asking there oopses in
   `mt76_mcu_send_and_get_msg()`.
2. `mt7615_mcu_parse_response()` pulls the 28-byte `mt7615_mcu_rxd` for every command that returns
   payload, by a branch per command. Without one for `EFUSE_ACCESS` the header is read as the
   payload, which is why `valid` read zero and the data looked like pointers.
3. `mt7615_init_device()` installs the tx worker the mcu sends through, so it cannot move after the
   firmware download.
4. `mt76s_sdio_irq()` drops every interrupt until `MT76_STATE_INITIALIZED` is set. The command went
   out and the answer was discarded - the patch semaphore timeout that looked like a firmware fault
   for three iterations.

The reorder is behind a `mcu_first` profile flag: `mt7663u` and any other `mt7663s` keep the old
order byte for byte. `mt7921s` - same core, same bus, same module set - already registers after its
firmware is up, so this brings mt7615 in line with its own siblings rather than special-casing a
board.

### The driver is not tied to one firmware build

The factory N9 is `20181227001901f`. A second build, `20210706163620e`, with a ROM patch of a
different size (213054 against 178782), loads and behaves identically: association, both bands,
`d0:aa:5f:32:eb:f2` still read from the efuse. The CR4 and the EEPROM are byte-identical between the
two sets.

| Band   | factory fw TX | factory fw RX | 2021 fw TX | 2021 fw RX |
| ------ | ------------- | ------------- | ---------- | ---------- |
| 2.4GHz | 87            | 85.3          | 87.0       | 86.8       |
| 5GHz   | 148           | 151           | 152        | 149        |

No difference worth the word. Nothing in the driver assumes one image: filenames come from the
profile and the section table is read out of the image.

### The reorder fixed the reload

`mcu_first` closes the first ranked item as a side effect. Three consecutive
`rmmod mt7663s; modprobe mt7663s` cycles on the factory firmware each returned 0 and brought `wlan0`
back in about twelve seconds, with the N9 _and_ the CR4 both loading on the warm part - the download
that used to time out. After the third the board associates on 2.4 GHz in 2 s at 300 Mbit/s HT40 and
on 5 GHz at 866.5, keeps `d0:aa:5f:32:eb:f2`, and logs nothing.

That follows from the same ordering: a reload re-runs probe, which now sets `MT76_STATE_INITIALIZED`
and installs the tx worker before the firmware download, so the answers to the download commands are
serviced instead of dropped. The old order registered first and downloaded into an interface that
could not carry the replies on a warm part.

An earlier entry here blamed the reorder for a hang during `rmmod` and said the 2021 firmware does
not fix the reload. Both were wrong, and for the same reason: that test ran on the 2021 firmware, so
the firmware was the variable, not the reorder. On the factory firmware the reorder reloads 3/3.

The 2021 firmware is the remaining suspect for that hang - one attempt, so it is a lead rather than
a finding. It associates and benches identically to the factory build but has not reloaded cleanly
once.

### mcu_first breaks scanning, so nothing that depends on it ships

A cold power-on on the baseline build scans 25 BSSes and then 29. The same board minutes later, on
the build with `mcu_first` and `efuse_mac`, scans 0. The AP is up throughout - the host running the
test is associated to it.

That single difference accounts for the whole of the afternoon. With no scan results nothing
associates; a failed association leaves the firmware unable to power down, so the next `rmmod` and
`modprobe` cannot take ownership and the reload fails too. Every "association is flaky" and "the
reload is flaky" reading above is downstream of a driver that cannot scan.

Earlier entries claimed the per-unit address and the warm reload were both done. They work, and they
both need the reorder, and the reorder is not shippable. Both flags are off in the tree.

The lead: `mt7615_init_work()` - `mt7615_mcu_set_eeprom()`, `mt7615_mcu_ce_init()` - runs after
`mt76_register_device()` under the reorder, so mac80211 can ask for a scan before the firmware has
been told anything. The old order registered last, after all of it.

### Scans work; the supplicant never sees them

`probe_req_num` was zeroed on the `hw_scan_v0` path, so an active scan sent no probe requests and a
directed scan returned nothing. `iw dev wlan0 scan` hid it by asking for a wildcard scan and reading
beacons. Two probes are sent on any scan carrying an ssid now, which moved `wpa_supplicant` from
SCANNING to DISCONNECTED.

Everything around the scan is healthy: `fw_ver` 3 so the offload path is taken, `hw_scan` registered
and called, `MCU_EVENT_SCAN_DONE` (`0x0d`) arriving, `MT76_HW_SCANNING` clear on every entry, and
back-to-back `iw` scans returning 19 and 26 BSSes with the target among them at about 2.4 s each.

`wpa_supplicant` still never records a BSS and never attempts association - with its own config or
the system's. In one run it issued 35 triggers and 2 reached the driver, the rest rejected from
above with `-16`, which is what a 2.4 s scan does to a supplicant retrying every second.

### mt76 authenticates, associates and completes the handshake

Four faults, each measured, in the order they had to be fixed.

**A ninth descriptor word landed on the frame.** The command path's descriptor is 32 bytes and
`mt7663_usb_sdio_write_txwi()` places it at `skb->data - len`, so the `txwi[8]` that
`mt7615_mac_write_txwi()` wrote for every bus that is not mmio fell on the frame's own frame control
and duration. Every management frame this driver has ever sent went out malformed, which is why the
access point never acknowledged one and never answered. Guarding it with `!mgmt_as_cmd` gives
`auth_transaction=2 status_code=0` and an association.

That one bug produced the three symptoms chased separately for a day: transmit reporting
`TX_RESULT_MPDU_ERROR` after 30 attempts, no authentication response, and no frames handed up while
parked on the channel. The account in the todo of mac80211 never assigning a channel was measured on
a phy whose scan state was already wedged and is withdrawn.

**Nothing told the firmware the bss had connected.** `.sta_event` was unset on the sdio driver, so
the state 2 -> 3 transition sent nothing. It now sends what the vendor sends there: `0x12` connected
with the ssid and bssid, `0x13` state 3 with the aid, `0x16`, `0x19`.

**The firmware translated EAPOL to 802.3.** mac80211 takes an 802.3 frame only through a station's
fast-rx path, set up once the station is authorized - so the frames that would authorize it can
never be translated. `mt7615_mac_init()` holds the `ETH_P_PAE` blacklist and is skipped whole for a
firmware that owns the table. `MCU_EXT_CMD(RX_HDR_TRANS)` goes unanswered here; clearing
`MT_DMA_DCR0_RX_HDR_TRANS_EN` works.

**An EAPOL frame has to go out as a command.** gen4m puts an 802.1X frame on TC4, the same transmit
class as management. Detecting it from `info->control.flags` proved unreliable - ordinary encrypted
data frames were routed as commands - so it is read from the frame: unprotected data whose LLC/SNAP
ethertype is `ETH_P_PAE`.

Measured after all four, from a cold boot: associated on round 1 in 2 to 4 s, -39 to -49 dBm,
`Key negotiation completed [PTK=CCMP GTK=CCMP]`, `CTRL-EVENT-CONNECTED`.

**The keys go to the firmware by command.** `mt7615_set_key()` ended in
`__mt7615_mac_wtbl_set_key()`, and `mt7615_mac_wtbl_update()` returns straight away for a firmware
that owns the table, so no key was ever installed. `0x07` `ADD_REMOVE_KEY` is sent twice now, the
pairwise key into the peer's entry and the group key into entry 0, which is what the firmware named
as the bss's own. The group key demonstrably works: an encrypted broadcast from the access point
arrives with `RX_FLAG_DECRYPTED`.

**Bulk data still does not pass.** No dhcp lease, and a ping answers once in five at best. What
separates a frame that arrives from one that does not is the encryption rather than the port: an
unencrypted EAPOL frame is acknowledged on either port, an encrypted data frame on neither, and both
ports write to the same `sdio_writesb(MCR_WTDR1, ...)`. Ruled out along the way: the sdio quotas
(`pse_data 256 pse_mcu 32 ple_data 403`), a fixed transmit rate on data frames, wmm set 0, the
peer's table entry, opening `MT_WF_RFCR`, and runtime power save.

**The forced MCU reset.** `halHifPowerOffWifi()` recovers a bus error with
`MCR_WHLPCR <- FW_OWN_REQ_CLR`, `MCR_WSICR <- GENMASK(31, 16)`, `MCR_WHLPCR <- FW_OWN_REQ_SET`. mt76
already names `MCR_WSICR`; only the bit was missing. A reload of a part whose firmware still answers
now brings `wlan0` back in one second with no mmc unbind. A part that has already gone quiet is past
it and still needs a power cycle.

### What the mt76 port settled about this firmware

**Settled while bringing the port up.**

**The firmware names every command it receives.** Its log is `FWLOG_2_HOST 0xc5` in the CE space,
reported as `MCU_EVENT_DBG_MSG 0x27`; the ext `0x13` mt76 sent times out. With the fallback in place
`echo 1 > /sys/kernel/debug/ieee80211/phy*/mt76/fw_debug` turns it on and it prints lines like
`HEM: CMD_ID:0x03 SEQ:15 LEN:992`. That is what tells a command the part acts on from one it merely
answers. It is verbose enough to disturb what it measures, so it is a probe, not a setting.

**Resetting the part takes Bluetooth with it.** The Wi-Fi and Bluetooth functions share one SDIO
card, so unbinding `d0070000.sdio` pulls the card out from under `btmtksdio`, which then wedges with
its reference count at -1 and floods the log with `Invalid bt type 0x80`. Take `hci0` down and
remove `btmtksdio` before the unbind, and reload it after.

**A blocking register read stalls the join.** `mt7615_set_channel()` ended with
`phy->chfreq = mt76_rr(MT_CHFREQ)`, which this part does not answer, so every channel set cost a
full MCU timeout and everything behind it timed out too. `chfreq` is only compared against a channel
number, so a firmware that owns the MAC takes it from the chandef.

**A timeout is not evidence of absence.** Several entries in the absent-command table were put there
because they timed out, while that stalled read was cascading timeouts onto everything behind it.
Re-tested with the read gone: `CHANNEL_SWITCH`, `EDCA_UPDATE` and ext `FW_LOG_2_HOST 0x13` are
genuinely absent - the first two wedge the driver if sent, and the third times out on its own.
`REMOVE_STA_RECORD 0x14` was on that list too and is not absent at all: with the vendor's action it
runs through cleanly.

**Reloading needs the part power-cycled.** `modprobe -r mt7663s` then `modprobe mt7663s` leaves the
firmware resident, and `MCU_CMD(PATCH_SEM_CONTROL)` then times out - the download cannot take the
patch semaphore from a running firmware. `__mt7663_load_firmware()` does guard against this, but
through `MT_TOP_MISC2_FW_N9_RDY`, which reads back zero on an MT7668 whatever the firmware is doing.
Unbinding and rebinding `d0070000.sdio` runs the `sdio-pwrseq` reset and the part comes back
identical to a cold boot - same scan counts, same signal - so the hardware reset is sufficient and
the gap is in the driver.

The bit that does answer is the host interface's own `WCIR_WLAN_READY`, bit 21 of `MCR_WCIR`, which
is what gen4m polls after a download, and `mt7663s_mcu_init()` now refuses on it - measured clear on
a power-cycled part and set on a reprobe.

The unload now does what `halHifPowerOffWifi()` does: `NIC_POWER_CTRL`, wait for that bit to clear,
hand ownership back. A warm reload gets as far as downloading and starting the N9, and then the
CR4's download request goes unanswered for the full MCU timeout. The ROM patch staying resident, so
that `mt7615_load_patch()` skips on `PATCH_IS_DL`, is the one state difference left from a cold boot
at that point.

**Settled before that.**

The data path is shared, so this is a port rather than a rewrite. gen4m's `HW_MAC_TX_DESC_T` is the
same 32-byte connac long-format TXD mt76 builds, DW for DW, and `HW_MAC_RX_DESC_T` matches
`mt7615/mac.h` field for field - `ucChanFreq` at DW1 bits 15:8 is `MT_RXD1_NORMAL_CH_FREQ`,
`ucHeaderLen` at 21:16 is `MAC_HDR_LEN`, `ucBssid` at 31:26 is `MT_RXD1_NORMAL_BSSID`. The register
map in `mt7615/usb_sdio.c` is used unchanged and reaches the registers - through the mcu, a command
and an event per access, so the driver should want none of them once the part is running.

The CE command space is shared by name, not just by id: `0x03` `SCAN_REQ_V2`, `0x0a`
`SET_RX_FILTER`, `0x0f` `SET_DOMAIN_INFO`, `0x1b` `SCAN_CANCEL`, `0x1c` `CH_PRIVILEGE`, `0x1d`
`UPDATE_WMM_PARMS`, `0xc5` `FW_LOG_2_HOST`.

Nothing the part emits enumerates its command set. `NIC_CAPABILITY 0x09` exists on both sides, but
its TLVs are TX resource, efuse address, coex, single SKU, checksum offload, MAC efuse offset and
R-mode. Capability has to be declared or learned from a timeout.

gen4m's enum is not the last word on what the firmware implements: `REG_READ 0xc0` is missing from
it and works on the box. Whether gen4m _sends_ a command is the reliable test, though: the ext
commands it sends are answered, and the ones that appear only in its enum are not.

## 2026-09-23 - the receive side after the keys, and what a measurement is worth

**`modprobe -r mt7663s` was not reloading the driver under test.** It leaves `mt7615_common` loaded,
and that module holds `mac.c`, `main.c` and `mcu_ce.c` - nearly every line this port changes. A new
leaf was being loaded against an old common module, and it reported success. Found because a debug
print appeared in `dmesg` while existing in no source file in the tree. All six modules have to come
out, youngest first; `/root/reload.sh` does that and then cycles the sdio host. Any A/B taken before
this may have compared a build against itself.

**Cycling the sdio host recovers the post-association wedge.** Unbinding and rebinding
`d0070000.sdio` on `meson-gx-mmc` removes the card and re-enumerates it, the firmware downloads
again, and `wlan0` is back in under a second - run against a part that had just answered
`Cannot get ownership from device` and `-110`. The doc said only a power cycle cleared it; it does
not. Iteration no longer needs the board touched.

**What arrives after the handshake is a block ack request and nothing else.** A probe at the top of
`mt7615_mac_fill_rx()`, before anything can reject the frame, counts every unicast frame the
firmware hands up: `widx 3` for auth, assoc and the EAPOL exchange, then from the handshake's last
frame `widx 255 sec 0` one per ~12 ms and nothing during a ping. Dumped at the frame rather than
inferred: `84 00 a0 4c d0aa5f32ebf2 7490bc123390 04 30 00 00` - control subtype 8, receiver this
station, transmitter the access point, compressed bitmap, tid 3, starting sequence 0. The EAPOL
frames that did arrive came in on tid 7.

**The firmware discards a unicast frame it cannot decrypt.** Forced onto software crypto so that no
`0x07` reaches it at all, a run is identical - so a firmware holding no key hands up no encrypted
unicast frame, and the same holds when a key is in and unusable.

**The cipher header is gone before the driver sees the frame.** A decrypted broadcast carries
`aa aa 03 00 00 00 08 00` immediately after its 24-byte 802.11 header. mac80211's ccmp path expects
that header present and removes eight bytes with a `memmove` and a `skb_pull` whatever the driver
says, so payload was being destroyed on every frame. `mt76_insert_ccmp_hdr()` puts one back.

**Two descriptor indices named entries the part does not have.** `mt7615_wtbl_size()` reports 128,
so the interface's own entry is 127 against a 32-entry table, and that is what every broadcast
transmit pointed at; it goes against the group key's entry, mt76's global wcid at 0, as the vendor's
does. `get_omac_idx()` returns 1 for a station while the ce commands name only bss 0.

**The receive filter was missing the unicast bit.** `0x0A` sent all-multicast and broadcast; the
vendor sets `PARAM_PACKET_FILTER_SUPPORTED`, which adds multicast and directed.

**Everything comparable now matches gen4m.** Its command header is 32 bytes, so a logged `LEN` less
32 is the payload: `0x07` 64, `0x12` 116, `0x13` 136, all equal to this port's. The pairwise key's
`Key Index 0xc0000000` is its transmit and unicast bits with key id 0; `Cipher 4`,
`Key Length 0x10`, zero rsc, the peer's address, the peer at entry 3 and the group key at 0;
`ucStaType` 65; `ucBMCWlanIndex` 255 in the station record, which `cnm_mem.c` hard codes, and 0 in
the bss info.

**Eliminated, each on a fully unloaded stack:** the key's contents and its table entry; replay,
since `RX_FLAG_PN_VALIDATED` leaves `rx drop misc` unchanged; block ack negotiation, since refusing
every session does not stop the access point aggregating and gen4m installs no receive agreement in
its firmware at all, keeping `arRxBaTable` in the host; and `0x16`, `0x19` and `0x0A`, since
dropping all three to match the vendor's association set changes nothing.

**The bss and its edca table named different queue sets.** `0x12` carried a hard-coded 2 while
`0x1D` programmed into `wmm_idx`, 0, and a descriptor's `q_idx` counts from the same 0. gen4m takes
all three from one `prBssInfo->ucWmmQueSet` - `nic.c:1426`, `nic.c:2054` and `nic_tx.c:1072` - which
with dbdc disabled is `DBDC_5G_WMM_INDEX`, 0. Corrected, and it does not make a ping answer either.
The access class order `0x1D` wants is BE, BK, VI, VO, not mac80211's VO, VI, BE, BK; that mapping
was right.

**Nothing leaves the lmac port, and that is what withheld every unicast frame.** A data frame handed
to it draws a transmit status and never reaches the air, so the access point had nothing to answer.
Sent on the command port instead - where gen4m puts management and 802.1X - unicast works both ways
at once: the gateway reaches `REACHABLE`, a dhcp offer arrives, rx runs at 130-144 Mbit/s MCS 14-15,
and 46 decrypted unicast data frames land in a run where there had been none. This was recorded as
ruled out earlier; that reading came from a stale `mt7615_common`, which is exactly the hazard
above.

`mt7615_tx_as_cmd()` collapses to `dev->fw->ce_join`, so the LLC/SNAP `ETH_P_PAE` sniffing it used
to do is gone. The rate handling on that port was written for management frames, so the block
pinning an mmpdu to the bss's lowest basic rate is now scoped to non-data frames - data reaches MCS
7 to 8 rather than sitting at MCS 0. Setting `MT_TXD6_FIXED_BW` on data made things worse, so the
bandwidth stays the firmware's to pick.

**Aggregation has to be refused.** No ADDBA request ever reaches mac80211 - the unicast frames
handed up during a join account for themselves as auth, association response and the EAPOL
exchange - yet the access point sends block ack requests, so the firmware negotiates a session the
host never learns about and mac80211 has no window to reorder against. Enabled: `rx drop misc` 80
and a ping at 808-1836 ms. With `tx_ampdu` and `rx_ampdu` clear in the station record the firmware
declines, the block ack requests stop and `rx drop misc` falls to 3-10.

**What is left is transmit loss.** `tx failed` is a third of transmits, 33 of 96, and a ping answers
1 to 3 of 20 at 345-1500 ms. Every frame now shares the command queue, whose credits this part
returns one per command on TQ15, so a queue that used to carry a command every few seconds carries
all the traffic.

**The two queues behind the command port are not equal.** A transmit status for a lost frame carries
a transmit count of zero and `MT_TXS0_QUEUE_TIMEOUT`, so the firmware took the frame and aged it out
without one attempt. Moving data to `MT_MCU_Q0` and leaving management on `MT_MCU_Q1` takes a ping
from 2 of 20 to 5 or 6, and the queue timeouts from 44 of 86 to about a quarter.

Two changes that look right and measure worse, both reverted:

- asking for a transmit status only for a frame mt76 tracks. It cuts the status events from 87 to
  35, as intended, and costs association reliability and half the answered pings: 1 to 4 of 20
  against 5 to 6, and one run in three never leaving SCANNING.
- leaving the rate to the firmware rather than taking what mac80211 left in the frame.
  `mt7615_mac_set_rates()` is skipped for this part so nothing chose that rate, and removing it
  stops association dead - twice in a row, and again when narrowed to data frames only.

Measured over three cold reloads with all of it in: associates 2 to 3 times of 3 in 4 s, a ping
answers 4 to 6 of 20, round trips 184-1472 ms and 2-3 ms when the queue is clear.

**It wants a power save profile.** gen4m hands its firmware `0x05` `POWER_SAVE_MODE` at init - the
bss index and `ENUM_PSP_CONTINUOUS_ACTIVE`, four bytes - and this port never did. Sent as part of
the join it takes association from two runs of three to three of three, and leaves the loss where it
was.

Two more eliminations on the transmit loss: a generous retry count on data as well as management
changes nothing, 5 to 6 of 20 either way; and pacing the traffic to one ping a second rather than
three makes it worse, 1 of 10, so the command queue is not overrunning. The loss is bimodal - the
same build answers at 1.7-17.8 ms in one run and several hundred in the next.

**The channel privilege is held, not handed back, and that is what works.** gen4m releases it when
the grant runs out with the bss connected - `aisFsmReleaseCh()` under `AIS_STATE_NORMAL_TR` in its
channel timeout handler - so the same was done at the end of the association here. It measures
worse, 1 to 2 of 20 against 4 to 6, three runs each. Reverted, and the difference from the vendor is
not explained.

**The lmac port was tried again and still carries nothing.** Everything else had moved since it was
last measured - the wmm queue set, the own-mac index, the broadcast table entry, the power save
profile, aggregation refused - and routing ordinary data back to it gives 0 of 20 with the receive
rate at 1.0 Mbit/s, which is the reading that means no unicast arrives at all. The first attempt at
this test also routed EAPOL there, which breaks the handshake by construction; the second kept EAPOL
and management on the command port and only moved ordinary data.

**Nor is the lmac port's descriptor the reason.** Giving a data frame there the 64-byte descriptor
an mt7663 takes, `MT_USB_TXD_SIZE` with the ninth word written, while management and 802.1X keep the
short one on the command port, is 0 of 20 as well. Both descriptor lengths were measured on that
port and neither carries anything.

**The vendor driver was rebuilt and it loads after all.** The earlier note that it binds and never
creates `/proc/net/wlan` does not reproduce: unload the mt76 stack, cycle the sdio host, `insmod`
the built module, and `/proc/net/wlan` and `wlan0` both appear. What the earlier attempt lacked was
the host cycle. Its debug control is not at `/proc/net/wlan/dbg_level` - that directory is empty -
so the `VENDORTXD` dump added to `nicTxFillDesc()` could not be turned on, and the data frame
descriptor is still uncaptured.

**That vendor measurement is withdrawn.** It read 2 of 20 pings, no better than this port, and was
taken with the instrumented rebuild on a part that had been reloaded all night. The vendor driver
loses nothing on this access point, so the residual loss is this port's to fix.

**Unbinding the sdio host while the vendor driver holds the function oopses.** `meson_mmc_remove()`
took a null dereference through `device_release_driver_internal`, the controller was left unbound
and the bind after it hung. The box stays up and reachable over usb ethernet, and its persistent
state is unchanged - `blacklist wlan_mt76x8_sdio`, so `mt7663s` loads at boot - but only a reboot
brings the controller back.

**Where the vendor's debug control went.** The path was right and the code is built:
`PROC_ROOT_NAME` is `wlan`, `dbg_level` is created at `gl_proc.c:1412`, `-DWLAN_INCLUDE_PROC` is in
the ccflags and `gl_proc.o` is in the Makefile. What creates the directory is `procInitFs()` at
module init; what creates the entries inside it is `procCreateFsEntry()`, called from `wlanProbe()`
at `gl_init.c:2550` once the net_device has registered. The directory was empty of everything, not
just `dbg_level`, so that call either never ran or failed on its first entry - and `wlanProbe` logs
`init procfs failed` when it does. Next attempt: load it with the kernel log clear and read dmesg
for that line before anything else.

**The lmac port does transmit, and that corrects an earlier reading.** Counting submissions against
statuses rather than inferring from the ping: thirty-odd data frames go out on `q_idx` 1 against the
peer's table entry, and a status comes back reading no ack timeout, no queue timeout and a count of
1 - a frame that went out and was acknowledged. So the port carries some traffic and loses the rest,
the same as the command port, which is merely better at it. The earlier "nothing leaves the lmac
port" was inferred from a ping answering none of twenty and was too strong.

**Traced gen4m's transmit path in source instead of guessing at it.** `arTcResourceControl` in
`nic_tx.c` is the table the runtime capture was after all along: TC0-3 go to `PORT_INDEX_LMAC` on
`MAC_TXQ_AC0-3`, TC4 - management and 802.1X - goes to `PORT_INDEX_MCU` on `MCU_Q1_INDEX`, and an
lmac queue gets `ucWmmQueSet * WMM_AC_INDEX_NUM` added to it. So data belongs on the lmac port, the
mcu port takes only TC4, and `MT_MCU_Q0` was never a vendor behaviour - it was a workaround that
measured better and is now reverted.

Found and fixed from the same read: the ethertype offset. gen4m writes
`(NIC_TX_PSE_HEADER_LENGTH + ucMacHeaderLength + ucLlcLength) >> 1` into every descriptor; this port
wrote it only for a frame on the command port and left the llc out, so it pointed three words short
of the ethertype. It measures the same - 3 of 20 against 4 to 6 - and is kept because the vendor
does it.

Eliminated by reading rather than by a run: the remaining life time, where
`TX_DESC_TX_TIME_NO_LIMIT` is 0 so leaving the field zero is already no limit; the descriptor
length, `NIC_TX_DESC_LONG_FORMAT` being 8 dw for every tc including data; and
`HW_MAC_TX_DESC_APPEND_T`, 44 bytes of dma buffer pointers written by `nicTxComposeDescAppend()`,
which the sdio path never calls.

What is left is sharp: gen4m puts data on the lmac port and this port cannot. With every other
difference above closed, data routed there answers 0 of 20 and on the command port 4 to 6 - and the
lmac port is not refusing the frames, since they are submitted against the peer's entry on `q_idx` 1
and one comes back acknowledged.

**The data credit pool is never refilled, and that is a real leak.** A probe on `intr.tx.wtqcr`
shows this part reporting one credit at a time and only on two counters - TQ3 when a data frame
completes, TQ15 when a command does, which is `HIF_TX_AC3_INDEX` and `HIF_TX_CPU_INDEX` from
`arTcResourceControl`. `mt76s_refill_sched_quota()` takes `ple_data_quota` from TQ5 to TQ8, where
nothing is ever reported, while `mt76s_tx_pick_quota()` charges a data frame one ple credit and
gates on it. Over 12 s of traffic `ple_data_quota` fell 326 to 258 and never rose, `pse_data_quota`
232 to 230, and `pse_mcu_quota` climbed 49 to 51 because patch 0006 already points the command pool
at TQ15. From its initial 403 the data pool empties in about a minute, after which the data path
stops for good. `data_quota_pkts` charges one per frame against the pool the part actually reports
and stops gating on the absent one; `ple_data_quota` then holds at 403.

**Also from the same trace:** gen4m leaves `PKT_FORMAT` at 0 for anything that is not a command, so
a data frame is `TXD_PKT_FORMAT_TXD` - `MT_TX_TYPE_CT` here - where mainline uses `MT_TX_TYPE_SF`
for any bus that is not mmio. Changed to match.

Both of those are on the lmac path, which this profile does not take, so neither is exercised by a
run here. Kept because they are what the vendor does.

**Eliminated by reading, no run spent:** the sdio data port, since gen4m writes every frame to
`kalDevPortWrite(MCR_WTDR1, ...)` exactly as mt76 does.

**And the lmac port is still unexplained.** With the queue set, own-mac index, broadcast entry,
power profile, aggregation, ethertype offset, packet format, credit accounting and bus port all
matched to gen4m, data routed to the lmac port still answers 0 of 20 while the command port answers
4 to 6.

**The per-tc lifetimes and retry limits, read rather than guessed.**
`NIC_TX_AC_BE/BK/VI/VO_REMAINING_TX_TIME` are all `TX_DESC_TX_TIME_NO_LIMIT`, which is 0, so leaving
`MT_TXD2_MAX_TX_TIME` unset is right for a data frame after all. `NIC_TX_MGMT_REMAINING_TX_TIME` is
2000 ms, which is 61 in the field's units of 32 tu, and this port sends everything on that queue, so
it is set now. The retry limits are 30 for both, which `MT7615_CE_TX_COUNT` already matched. It
measures the same, 3 of 20, and is kept because it is what the vendor gives that queue.

**Header padding eliminated by reading:** `NIC_TX_DESC_HEADER_PADDING_LENGTH` is 0, so the vendor
leaves `MT_TXD1_HDR_PAD` at zero exactly as mainline does.

**And the packet format finding confirmed at its source:**
`if (prMsduInfo->eSrc == TX_PACKET_MGMT) HAL_MAC_TX_DESC_SET_PKT_FORMAT(prTxDesc, TXD_PKT_FORMAT_COMMAND)` -
only a management frame is given `COMMAND`, so a data frame keeps the memset default of 0.

**The lmac port survives one more elimination.** Pinning a data frame there to the bss's lowest
basic rate, on the theory that the hardware rate table was never populated, is 0 of 20 as well.

**The command queue holds seven frames, and that is the ceiling.** `HIF_TX_BUFF_COUNT_TC4` in the
sdio hif's own header is 7, against 167 for TC1 which carries data be and 8 for TC0. This port sends
every frame on TC4 and lets `pse_mcu_quota` climb to 40 or 50 while charging one per frame, so it
offers fifty frames to a queue that holds seven - and a transmit status of `QUEUE_TIMEOUT` with a
count of zero is precisely what that looks like from the other side. It also explains why an
association and a handshake work while bulk data does not: those need a handful of frames and fit
inside seven.

`mcu_quota_max` caps the pool at seven. A ping answers 6 of 20 with it against 4 to 6 without and
the fastest round trip falls from 180-300 ms to 56 ms, which is inside the spread and not yet a
result.

The conclusion that matters is that no tuning makes a seven-deep command queue carry a transfer.
TC1's 167 is why gen4m puts data on the lmac port, so the lmac port is not an optimisation for this
part, it is the only way it can carry traffic - which promotes it to the first item on the ranked
list.

**The lmac port wants an 802.3 frame, and that is what "the firmware owns the mac" means.**
`nicTxGenerateDescTemplate()` builds gen4m's per-tid template for an os packet with
`eSrc = TX_PACKET_OS` and `fgIs802_11 = FALSE`, and `nicTxComposeDesc()` turns that into
`SET_HEADER_FORMAT(HEADER_FORMAT_NON_802_11)` plus `SET_ETHERNET_II()`: the host hands the part an
ethernet frame and the firmware builds the 802.11 header. Every `fgIs802_11 = TRUE` in the tree is a
management or EAPOL frame - `rsn.c`, `tdls.c`, `p2p_func.c` - and those are exactly the frames that
go to the mcu port on TC4. A data frame is never 802.11.

mt76 hands 802.11 for everything, so the lmac port has been given a frame shaped for a port that
does not serve it. That explains what no descriptor field could: the frames are submitted against
the right table entry and queue, some come back acknowledged, and the access point answers nothing.

mt76 already has the mechanism on the connac2 side - `mt76_connac_mac.c` splits on
`IEEE80211_TX_CTL_HW_80211_ENCAP` into `mt76_connac2_mac_write_txwi_8023()` with
`MT_HDR_FORMAT_802_3` and `..._80211()` - and mt7615 has only the 802.11 half. Next: add the 802.3
half, `SUPPORTS_TX_ENCAP_OFFLOAD` on the hw and `IEEE80211_OFFLOAD_ENCAP_ENABLED` on the vif. Keys
go in by command and the firmware encrypts, so the hardware encryption encap offload requires is
already how this part works.

**Two more eliminations from the same read:** gen4m never touches the dma scheduler - no `DMASHDL`
reference anywhere in the tree - so the group quotas and refill mask `mt7663u_dma_sched_init()`
writes are not something the host programs for this part, and sdio never called it anyway. And the
own-mac index is 0 for the ais bss, `HW_BSSID_NUM` being 4 and the reserve path falling back to 0,
which is what this port now sends.

**Giving the lmac port an 802.3 frame makes it carry traffic.** With mac80211's transmit
encapsulation offload on for this part, data routed to the lmac port answers 4 to 5 of 20 where the
same routing with 802.11 frames answered 0 of 20, and the command port answers 4 to 6. So the port
is no longer the fault and data sits on TC1's 167 buffers rather than TC4's seven. A counter
confirmed the offload actually engaged - 30 encapsulated frames against 35 802.11 ones in a run, the
latter being the management and EAPOL that still go to the mcu port, which is gen4m's split exactly.

What it took: `SUPPORTS_TX_ENCAP_OFFLOAD` on the hw, `IEEE80211_OFFLOAD_ENCAP_ENABLED` on a station
vif, `MT_HDR_FORMAT_802_3` with `MT_TXD1_ETH_802_3` beside it, the frame type synthesised as data
rather than read from a header that is not there, and the ethertype offset at
`(ETH_HLEN - ETH_TLEN + 4) >> 1` = 8, which is what the vendor writes.

`MT_TXD1_ETH_802_3` is `BIT(12)` on connac1 and mainline does not name it. gen4m's
`TX_DESC_NON_802_11_ETHERNET_II` is bit 4 of `ucHeaderFormat`; `HW_MAC_TX_DESC_T` puts that byte at
byte 1 of DW1, so the bit lands at 12, immediately below `MT_TXD1_HDR_FORMAT` at 14:13 - the same
place connac2 puts its own relative to its format field. The rest of the struct corroborates it:
`ucHeaderPadding` is byte 2, which is where mt7615 has the padding at 17 and the tid at 23:21.

The credit and quota fixes are both visibly holding on this path: `ple_data_quota` stays at 403 and
`pse_mcu_quota` caps at 7. Receive runs at 144 Mbit/s MCS 15 with 565 packets in twelve seconds.
What remains is 47% of transmits unacknowledged, which is now common to both ports and is neither
the port nor the shape of the frame.

**The hardware needs a default rate code, and without one it ages frames out.**
`nicTxUpdateStaRecDefaultRate()` and `nicTxUpdateBssDefaultRate()` fill `u2HwDefaultFixedRateCode`
in both the station record and the bss info with the band's lowest basic rate; this port left both
zero. Setting them took the transmit statuses from 16 acknowledged and 13 aged out of 33, to 26 and
3 - so the queue timeout that has dominated every measurement since the association work was a
hardware transmitter with no rate to fall back on, not a queue depth and not a port.

The encoding is shared, so no new table is needed: gen4m's `TX_MODE_OFDM` is `0x40`, which is mode 1
at `MT_TX_RATE_MODE`'s bits 6 and up, and `PHY_RATE_*` occupies bits 5:0 where `MT_TX_RATE_IDX` is.
`sband->bitrates[0].hw_value` already carries that code and the management path was using it.

**Checked and dead, before spending a run on either:** `ucRCPI`, which gen4m only ever sets to zero
in `cnm_mem.c` and never updates from a scan result, so its sta record carries the same zero this
one does; and the link speed fields, which nothing in the tree assigns.

What remains is a transmit loss of a different shape: `tx failed` is 41% while 79% of the statuses
that do arrive are acknowledged, so the gap is frames that draw no status at all.

**Part of `tx failed` is accounting, not loss.** gen4m requests a transmit status only for a frame
with a done handler - management and 802.1X - or under its `ucDataTxDone == 2` debug setting, and
asks for none on ordinary data. This port asks for one on every frame, and mt76 counts a frame whose
status never arrives as failed, so the 41% it reports overstates what is actually lost.

**The loss is per association, not per frame.** Counting icmp at the interface with `AF_PACKET`
across three fresh associations: 0 replies with 0 other inbound unicast, then 3 replies with 44,
then 2 with 20. The twenty requests leave the interface every time. So an association either has
working unicast receive or has none at all.

When it works the frames are right where they arrive - `widx=3 sec=4 wcid=3`, the peer's entry,
decrypted - and when it does not, not one unicast frame reaches the driver, not even a mis-tagged
one. That rules out the receive binding and puts the discriminator on transmit, settled at
association time. A good association reports 22 to 25 of 32 statuses acknowledged, 4 to 7 ack
timeouts and 3 queue timeouts, and answers 5 or 6 pings of 20.

**The retry count for a data frame is zero here, and it does not matter.** `mt7615_mac_set_rates()`
is the only thing that sets `rate_count`, and it returns early for a firmware that owns the table,
so `tx_count` is 0 and `MT_TXD3_REM_TX_COUNT` goes out as zero for every data frame while management
gets 30. `tx retries` confirms it: 0 across 56 frames. Giving data 30 took the retries to 15-32 and
giving it 8 took them to 14-22, so the field works - and neither changed the answered-ping count
beyond the noise. Reverted; the counter is either cosmetic or the hardware retries without being
told to.

**A correction on how that was read.** The batches came out 5-6 answered at zero retries, 0-3 at
thirty, 0 at eight, which looked like a monotonic degradation, and was reported that way mid-run.
The control - the original build, measured immediately after - returned 0, 4, 3. The swing between
fresh associations of one build covers the whole range, so a three-run batch cannot resolve an
effect this size, and `docs/todo/mt7668/method.md` now says so.

**Unicast receive works, and encap offload is what makes it work.** Counting at the interface with
the frames categorised: with the offload on, 14 to 46 inbound unicast frames arrive in a nine second
window, including unicast arp and tcp; with it off, zero. Six consecutive associations all had it,
and the ce command sequence was identical on every one -
`0x11 0x14 0x09 0x17 0x12 0x14 0x11 0x05 0x1c 0x13 0x1d`x4 `0x12 0x13 0x16 0x19 0x0a 0x07 0x07` -
with identical key commands. So the dead-association mode has become rare or is gone, and there is
no sequence difference left to find.

What does not arrive is the icmp echo reply, specifically: 20 requests out, 0 replies, while unicast
arp from the same router does arrive. The router has learnt our address from our frames, so layer
two is right and something above it is not.

**`RX_FLAG_PN_VALIDATED` retested and still negative.** The earlier test was worthless because no
unicast was arriving to be dropped; with the offload on and unicast arriving, setting it took the
inbound unicast count from 14 to 0. Reverted.

**On the naming, since it confuses every reading of this tree:** MT6632 is the combo die and the
chip id the driver checks, MT7668 is the wi-fi product and what the firmware files are called,
`76x8` is the module's wildcard over the family, and the headers descend from the MT6620 driver. The
build un-defines the siblings by hand. Mainline names by connac generation instead, which is why
this lives in `mt7615`. Written up in `patches/mt76-mt7668/README.md`.

**Not a gateway rate limit, and not arp alone.** Pinging a normal host on the segment answers none
either, so the gateway is not rate limiting icmp to itself. A permanent neighbour entry that
bypasses arp still answers 1 of 20, so the unresolved arp is a symptom rather than the blocker. The
router's lan address is `74:90:bc:12:33:8f` and the bssid `74:90:bc:12:33:90`, two interfaces of one
device, which any future test should account for.

Where that leaves it: layer two is right - the router has learnt this station's address from its own
frames, unicast arp and tcp from it arrive, and one neighbour reached `REACHABLE`, which needs a
round trip. What does not arrive is the reply to anything this station sends, and the rate is a few
percent rather than a mode that is on or off.

**An on-air capture, and a retraction.** A monitor interface alongside the managed one captures the
channel fine, and the first reading of it was that this station transmits multicast and never
unicast - 11 frames with this station as source, all multicast, against none unicast. That reading
is wrong. The direction bits settle it: 0 of those frames have ToDS set and all 11 are FromDS, so
every one is the access point forwarding this station's multicast back onto the bss, not a
transmission of ours. The capture holds 53 ToDS frames from other stations, so the instrument sees
uplink in general and this station's own uplink never - a radio does not receive what it transmits.

What the capture does establish: a multicast frame from here reaches the access point, since the
access point forwarded it; and the downlink is healthy, unicast data arriving at MCS 13 to 15 from
several hosts. Seeing this station's own transmissions needs a second radio, and
`docs/todo/mt7668/method.md` now says so.

**Also eliminated, each measured:** `MT_TXD3_PROTECT_FRAME`, which is set on every frame - a first
probe read it as clear, but it was placed before the block that assigns it; and `MT_TXD2_BA_DISABLE`
per frame, which changes nothing.

**One real detail worth keeping:** with encapsulation offload mac80211 passes the access point's
station for every frame including multicast, so the multicast special case in `mt7615_tx()` that
chose the global wcid never runs - every frame goes out against the peer's entry 3. The group key is
still the one used for a multicast frame, which the forwarded copies show as KeyID 1.

**On the air, properly this time: the access point forwards this station's multicast and never its
unicast.** An access point forwards a station's multicast back onto the bss and forwards unicast
between two of its own stations, and both arrive as FromDS, which this radio can see. So a forwarded
copy is proof a frame reached the access point. Over a capture taken while pinging, with permanent
neighbour entries so no arp was needed: 10 FromDS frames with this station as source, every one
multicast, zero unicast, and not one frame addressed to the peer station. Pinging that peer answers
0 of 12, the same as the gateway.

The same pairwise key decrypts what the access point sends here - frames arrive as `sec=4 wcid=3` -
so the key is right for receive. What it produces on transmit is something the access point does not
accept, and an access point that cannot decrypt a frame drops it silently. The fault is transmit
encryption against the peer's entry while receive against that entry works.

**Two measurement bugs of my own on the way there, both caught before they were written down as
findings:** a probe that read `MT_TXD3_PROTECT_FRAME` before the block that assigns it, and a count
of forwarded unicast that omitted `-e` from tcpdump, so the multicast exclusion matched nothing and
returned 10 where the answer is 0. Check the instrument before the conclusion.

**Transmit encryption eliminated, and the forwarded-copy argument qualified.** With
`mt7615_set_key()` refusing the pairwise key so mac80211 produces the ciphertext, a ping answers 1
of 12 - no better - so the firmware encrypting against the peer's entry is not what loses the
traffic.

That run also undermined the previous entry's reasoning. One ping was answered while the count of
forwarded unicast copies was 0, which cannot both be true if a forwarded copy were the test: an
access point does not forward wired-bound traffic onto the bss, so nothing addressed to the gateway
can ever appear as one. And the host used as a "peer" only ever appeared as the source of FromDS
frames, which is what a wired host looks like through a bridging access point, so station to station
forwarding was never exercised. The claim that this station's unicast never reaches the access point
is withdrawn.

Doing it properly needs a destination known to be wireless. The capture names four by their ToDS
frames - `c0:4e:30:a5:56:ac`, `b0:4a:39:93:3f:23`, `64:09:ac:e0:5a:fc`, `40:5b:d8:eb:43:fb` - and
their addresses are not known here.

**The loss is on transmit, measured from the access point's side.** The monitor interface cannot see
this station's uplink but sees the downlink perfectly, so what the access point sends back measures
how much of the uplink arrived. Twenty pings to the gateway, permanent neighbour entry, one capture:
3 FromDS frames to this station from the gateway, 8 from all sources, 1 ping answered. Three replies
for twenty requests - so the replies are not lost coming in, they are never generated, because the
requests do not arrive. That is about 85% of the loss on transmit and takes the receive path out of
it.

And it is not the frame's contents. In the software crypto run the encapsulation offload was off, so
mac80211 built the entire 802.11 frame - header, llc and snap, ciphertext - and the part only had to
transmit it; that answered 1 of 12. Whatever is lost is lost after the driver hands the frame over,
which is why no descriptor field, port, queue, credit, rate or key has moved it.

**The sdio write path matches gen4m in every respect.** Its `sdio.c` pads each frame with
`TFCB_FRAME_PAD_TO_DW`, which is `ALIGN_4`, ends a coalesced burst with one dword of zero
(`HIF_TX_TERMINATOR_LEN` 4), writes to `MCR_WTDR1`, and accumulates frames at `u4WrIdx` flushing
when the next will not fit. mt76 pads to 4, writes `memset(xmit_buf + len, 0, 4)` and then `len + 4`
to `MCR_WTDR1`, and coalesces into `xmit_buf` the same way. The terminator looked like the gap -
mt76 only obviously writes one in the firmware download path - but it writes one for every burst.
Eliminated by reading, no run spent.

**The firmware says why it drops our data frames, and the offset gives it away.** Turning its own
log on with `fw_debug` and pinging produced, 43 times in 40 pings:

    <CR4>Warning: ucBssIndex > CFG_BSS_NUM. Drop it. ucBssIndex = 51

Idle, with nothing sent from here, there are none, so the drops are caused by this station's own
transmissions. The values decode exactly: the gateway is `74:90:bc:12:33:8f` and byte 4 of that is
`0x33`, which is 51, seen 41 times; the other host tried is `f4:d4:88:65:2d:93` and byte 4 is
`0x2d`, which is 45, seen twice.

So the CR4 reads byte 4 of the ethernet destination as its bss index. In absolute terms that is
offset 36, four bytes past the end of the 32-byte descriptor - and `ucBssIndex` sits at offset 4 of
`HW_MAC_TX_DESC_APPEND_T`, after `u2PktFlags` and `u2MsduToken`. The firmware wants that append
header between the descriptor and the frame, and this port puts the ethernet header there instead.

That also explains why management and 802.1X on the 802.11 path were never affected: they do not go
through the CR4 data path. `nicTxComposeDescAppend()` looked like pcie-only metadata because the
sdio path does not call it, and that reading was wrong - the firmware reads it.

**The append, and mainline unicast works.** `nicTxFillDesc()` places a `HW_MAC_TX_DESC_APPEND_T`
between the descriptor and the frame of every `TX_PACKET_TYPE_DATA` packet and none on a management
one, under no host-interface guard, and `u2TxByteCount` counts it. That is what the CR4 was
reading - `ucBssIndex` sits at offset 4 of the append, which is absolute offset 36, four bytes past
the descriptor, exactly where this port had the ethernet destination. `nicTxComposeDescAppend()`
looked like pcie-only metadata because no sdio code calls it directly; that reading was wrong.
Writing it takes the drop count to 0 and the firmware log clean.

That left a ping at 8 of 20 and a round trip whose minimum was 1.9 ms and maximum 1041 ms. Varying
the send interval split it in two: at 50 ms, 11 of 12 arrive - exactly one lost, the last, with
nothing behind it - and at 300 ms and 1 s, 3 to 4 of 12 arrive but in under 16 ms when they do. So
the ones that worked were never slow, which ruled out queueing and pointed at whatever the firmware
does with a frame it is handed on its own.

A probe on the transmit status said it outright: 23 of 45 reports carried an ack timeout with a
transmit count of **zero**, and 10 a queue timeout, also zero. `MT_TXD3_REM_TX_COUNT` was taken from
`msta->rate_count`, and `mt7615_mac_set_rates()` only runs for a frame carrying
`IEEE80211_TX_CTL_RATE_CTRL_PROBE`, which a firmware that picks its own rates never sees - so the
count was 0 and every data frame asked for no transmission at all. gen4m gives every traffic
class 30.

With both in, 103 of 105 statuses are acknowledged at one attempt. Measured on the box: associates
in 4 s first try, arp resolves the gateway from a flushed cache, 43 of 50 pings at 0.2 s, **5 of 5
to 1.1.1.1 off the local network with no loss** at 6.8-18.7 ms, and iperf3 pushes 13.8 MB in ten
seconds at 11.5 Mbit/s with the link reporting MCS 15 both ways and 0 interface errors. Two earlier
eliminations were taken on a build the CR4 was dropping everything on and are void: that a generous
retry count on data changes nothing, and that pacing the traffic makes it worse.

What is left is throughput well under the negotiated rate, and the aggregation the firmware has to
be told to refuse is the first thing to look at.

## 2026-09-24 — aligning against the vendor source, and the upload wedge

Measurement first, because three readings were artefacts: a "332 Mbit/s download" went over Ethernet
(eth0 answers arp for the wlan address unless `arp_ignore=1`); several "0 bytes" uploads were
`timeout` killing iperf3 before its summary; and this Mac is on Wi-Fi, so tests now run against
plex, wired, where only `iperf3 -s` is started.

Aligned with gen4m, each read from its source or captured bytes:

- `EVENT_ID_RX_ADDBA` `0x0a` and `RX_DELBA` `0x0b` now start and stop mt76's host reorder buffer
  with the firmware's own tid, ssn and window; `rx drop misc` fell from 376 to about 20.
- A-MSDU in A-MPDU is `AmsduInAmpdu & HtAmsduInAmpdu`, off for an HT peer.
- `MT_TXD2_MULTICAST` was taken from `hdr->addr1` on an ethernet frame, which is the destination's
  fifth byte - odd for both the gateway and plex, so their unicast went out flagged group-addressed.
- The station record's `u2AssocId`, `u2ListenInterval`, `ucRCPI` and `u4TxRateInfo` were 0 against
  the vendor's 4, 6, `0x82` and 1; the aid was the peer's. The same aid bug was in `0x16`.
- The firmware reports its transmit budget in `GET_NIC_CAPAB` `0x8a`, `TAG_CAP_TX_RESOURCE`: 7
  frames on the mcu port, 127 on the lmac port. mt76 never asked and let 240 in.
- gen4m folds all twelve data counters, TQ0-TQ11, into its data budget; mt76 read TQ0-3, so the pool
  drained to 0 and transmit stopped.

The upload wedge is not solved. With the budget right, a sustained TCP upload still leaves
`ksdioirqd/mmc1` and `mt76-sdio-txrx` in D with nothing in the log: a CMD53 that never completes. It
is not coalescing - one frame per write wedges the same way. Unbinding the host frees both. The
first box hang today followed the same state.

Reload after a wedge fails: the CR4 image times out (`MCU init failed: -110`) and `rmmod` then
oopses in `device_del` after a WARN flushing an uninitialised work, leaving `mt7663s` stuck.

## 2026-09-24 evening — the upload stall

A sustained transmit wedged the bus, and early today that could hang the box. Three causes, in the
order they were found:

- The stall's surface was the shared sdio host held by `btmtksdio_txrx_work`, spinning on
  `Invalid bt type 0x80`. Type `0x80` is the combo firmware's debug channel: the firmware had
  asserted and was dumping its core through the Bluetooth function, which mainline btmtksdio does
  not know and logs per packet to a 115200 serial console while holding the host.
- The dump named the assert: `wifi_uni_mac_7668/nic/nic.c #2431`, WIFI task. The vendor driver runs
  the same bidirectional load for two minutes without it, TX 54-65 and RX 28-38 Mbit/s.
- Counting credits per transmit queue found about 2% of data-pool frames returned on TQ15, the
  command counter. They were management frames routed to the mcu port through a data queue: charged
  to data, never to the seven-deep command queue, which they overran. Charging each frame by its
  descriptor's port bit makes charged equal returned on both pools, and three 60 s bidirectional
  runs then pass with no assert.

Ruled out on the way, each measured: the data rate left to the firmware, receive aggregation, the
per-class depth, a status per data frame, mac_work's register reads, sdio write coalescing.

The box went down twice more. Once was a boot-time hang with `mt7663s` loading from udev and
`wpa_supplicant` starting on it; `blacklist mt7663s` now keeps it out of boot. The fix for that was
first written to the stick from the Mac with the repo's `e2cp`, which corrupted the ext4 directory
entry it replaced (`deleted inode referenced`, then `emergency_ro`). A kernel command line on the
FAT partition forced `fsck` in the initramfs before the root was mounted, and the file was written
again on the box.

## 2026-09-25 — both bands, and the scan

- 5 GHz joined once scans reached channel 40. A 5 GHz-only scan returned nothing, and a full one
  found only passive channels. Filled as gen4m fills `CMD_SCAN_REQ_V2` - a channel list only below
  32 channels, a full scan above, and the probe count, dwell and timeout all left at zero - every
  scan kind completes and finds the access point: one channel 8 of 8, four channels 5 of 5.
- mt76's own values were the fault. With its 60 ms dwell and a timeout of exactly one dwell per
  channel, a one-channel scan of 2437 found nothing in 10 of 10.
- A 5 GHz download ran at 1 Mbit/s: UDP at 100 Mbit/s lost exactly half its datagrams. The vht peer
  was offered a-msdu in a-mpdu, as the vendor offers it, and mt76's reorder buffer kept only the
  first of each pair of subframes. Offered neither way, 5 GHz carries 120 down.
- Transmit aggregation works once command-port frames are charged correctly: 2.4 GHz upload 49
  to 63.
- The host has no sdio interrupt line and the core polls for one every few milliseconds. mt76 now
  reads the status block itself while frames wait for credit; 5 GHz upload 48 to 78.
- `bench.sh` failures looked like the regulatory domain set before `up`; an A/B of eight joins
  showed no difference, and the failures came in a run of three together.
- Upload was bounded by how fast returned credit reached the next sdio write: about 1340 writes a
  second of six frames each, half the bus idle. Polling the status block longer and finer took UDP
  upload from 69 to 100, and one data pool of the firmware's full 127 frames - gen4m's five pools
  sum to the same - took it to 108. 2.4 GHz now measures 79 up and 92 down against the vendor's 83
  and 91; traffic both ways at once runs 39 up and 34 down with no firmware fault.
- 5 GHz upload is bus-bound. Timed over 2 s of UDP upload at 110 Mbit/s: data writes took 67% of the
  time (about 9 KB each, 20.5 MB/s against the 25 MB/s of a 4-bit bus at 50 MHz), status-block reads
  14%, idle 19%. The vendor's 154 fits the same bus by reading its release counters inside receive
  reads (enhance mode) rather than on their own. Polling finer than 30 us made it worse, 73;
  skipping the WTBL airtime reads the vendor never makes gave 108 to 112.
- btmtksdio `0002`: type `0x80` on the Bluetooth function is the combo firmware's debug channel; a
  Wi-Fi firmware assert sends its core dump down it, hundreds of packets opening with `0xfc6f`.
  Logging each one from the worker that holds the shared sdio host hung the box at a 115200 console.
  Dropped quietly, one ratelimited `firmware core dump` error; `hci0` still comes up.

## 2026-09-25 — 5 GHz upload at the vendor's rate

- The bus-bound reading above was wrong. Counters in the sdio worker showed every write carrying
  exactly 7 frames and the ring never deeper than 7, with the cpu 77% idle and 1-in-3 batches
  stopped on credit. mac80211 held the ring there: with no rate reported it estimated each frame's
  airtime at VHT-MCS 0, 20 MHz, and AQL stopped at about 7 frames. A rate written into the wcid by
  hand gave 64 KB writes and a ring 70-200 deep, and upload stayed at 94-100: the air, not the bus.
- `GET_STA_STATISTICS 0x85`, answered by event `0x21`, carries the firmware's own `u2LinkSpeed` in
  0.5 Mbit/s: 288, 144 Mbit/s, steady under load - HT20 two streams on an 80 MHz bss.
- Nothing told the firmware the link's width: the bss rlm block, the channel request and the station
  record left sco, width, centre segment and every vht field at zero. Filling them moved it to VHT20
  one stream at 78-86 Mbit/s with the packet error rate climbing, and upload fell to 48-53.
- The vendor's own payloads for a 5 GHz join, dumped from `wlanSendSetQueryCmd()`, differed in the
  station record's `ucVhtOpMode`: 0x12, 80 MHz and two receive streams, against 0. gen4m fills it
  from the peer's operating mode notification or, without one, from the bss width and its own stream
  count. With it the firmware reports 866.5 Mbit/s and upload measures 154-156 against the vendor's
  148-154, 115 and 133 in two other runs. Download rose to 142.
- The station and bss default rate code went as mt76's `hw_value`, 0x10b; the firmware's code for
  OFDM 6M is 0x4b. Fixed with the rest.
- Still different from the vendor's payloads, with no measured effect: rcpi 220 where it sends 158
  (the signal average is empty at the join), no `tx_bf_cap`, mac80211's filtered vht capabilities
  where it sends the peer's own, listen interval 5 against 10, and in the rlm block `gf`,
  `ht_op_info2`, the RIFS bit and `vht_basic_mcs`.
- A 32-frame threshold before a data write, as gen4m has for its interrupt path, made no difference
  either way. Dropped.
- 2.4 GHz now joins channel 6 at 40 MHz, which the vendor does not, and measures 116 up and 101
  down.

## 2026-09-25 — joins, reconnects and the scan

- Scan hit rates here were measured wrong until now: `iw scan` prints cfg80211's cache, which keeps
  a BSS for 30 s. With `flush`, the vendor finds the 5 GHz access point in 10 of 10 full scans and
  10 of 10 single-channel scans; mt76 found it in 2 and 3.
- A passive scan of 5200 found it 3 of 3 while active ones missed: it beacons, but our probes went
  unanswered. Some active scans returned no BSS at all on a channel with three.
- The vendor sends `BSS_ACTIVATE_CTRL 0x11` for bss 0, with its own address, before every scan and
  takes it down after. mt76 scanned with the bss down. Activating it before a scan while not
  associated: 10 of 10 both ways, and 8 joins in a row from a reload in 4 s each, where 4 of 8 had
  failed.
- The probe carried mac80211's per-band elements (2.4 GHz rates, HT and VHT capabilities) ahead of
  the common ones, 259 bytes against the vendor's 24. Sending only the common ones changed nothing
  measurable; not kept.
- `AdapScan 0x0`, the one firmware setting gen4m sends whatever its config says, made no difference
  either way. Not kept.
- A reconnect without a reload never completed: the first scan after a disconnect never reported
  done, 6 of 6. The leave removed station record 3, the peer's table entry, while the record is 0,
  so the firmware kept the station. The vendor removes every station of the bss (`0x14` action 1)
  and orders the leave abort-pm, bss disconnected, remove, deactivate, then hands the channel back.
  Doing the same: 6 of 6 reconnects on each band in 1-15 s.
- mainline's beacon filter re-sends `SET_BSS_CONNECTED` on every association change, a disconnect
  included. Skipping it for this part made no difference once the leave was right; not kept.
- Moving the channel hand-back to the end of the join, which one capture suggested, was wrong: the
  vendor holds the channel for the whole connection. Reverted.
- The 20 s outage an unaddressed `ping -I wlan0` shows after a join is ARP flux: the reply goes to
  eth0's address and `ping_rcv` drops it with `NO_SOCKET`. Pinging from the wlan0 address, replies
  stop for about 2 s starting 3.7 s after association, every time. The vendor lost the first 8 s in
  one run and nothing in the next. With transmit aggregation off the gap is the same, and one run
  lost the first 8 s as the vendor's did.

## 2026-09-25 — a-msdu, the reply gap after a join

- The vendor's station record sets `rx_amsdu_in_ampdu` for a vht peer and leaves `tx_amsdu_in_ampdu`
  at 0, from `AmsduInAmpduTx 0` in its `wifi.cfg`.
- Offered receive a-msdu, 5 GHz download fell to 1 Mbit/s. The firmware splits an a-msdu but keeps
  each piece a one-subframe a-msdu: 802.11 header with the a-msdu bit, the 2-byte pad, then the
  subframe header. mac80211 takes those apart itself, but every piece after the first carries the
  same pn and was dropped as a replay. `RX_FLAG_ALLOW_SAME_PN` on all but the first and
  `RX_FLAG_AMSDU_MORE` on all but the last: download 144 and UDP 151, against 143 and 157 without
  a-msdu. The sdio bus bounds download either way. Kept, as the vendor has it.
- Transmit a-msdu in a-mpdu through the station record does not stall: upload 138-151, UDP 163, 60 s
  both ways without a fault. No gain; left off, as the vendor has it.
- The reply gap after a join: 4-5 frames aged out with no attempt 4.5 s after association, `TX_DONE`
  status 1 at the 6 Mbit/s management rate. mac80211's rate control starts a transmit session, sends
  an ADDBA request the firmware never transmits, and holds the tid until the request times out.
  gen4m never builds one: the firmware agrees transmit sessions itself.
- Handing the join channel back on authorize, as gen4m does when its grant runs out, left the gap as
  it was. Refusing `IEEE80211_AMPDU_TX_START` removed the gap but upload fell to 2 Mbit/s.
- `IEEE80211_HW_TX_AMPDU_SETUP_IN_HW` for a firmware that owns the mac: no gap in 3 of 3 joins, 5
  GHz 135-149 up and 144 down, 2.4 GHz 137 up and 116 down, where it measured 116 and 101.

## 2026-09-25 — sweep of the series

Patches backed up to `.bak/2026-09-25-vendor-parity/` first. A review of 0001-0012 against the rules
in `AGENTS.md`; each change built clean under `W=1` and was followed by joins, reconnects and a
bench.

- Bugs fixed: the fallback management rate went out as mt76's `hw_value`, VHT mode on 5 GHz; the
  firmware's block ack events changed the reorder buffer outside the mutex and after
  `rcu_read_unlock()`; a fixed command-queue depth of 7 that the firmware's own report then
  overwrote.
- `0005` is now a `bool mcu_cmd_absent` op: the `SILENT` policy had no user. The absent-command
  bitmap, whose ce and uni halves overlapped past 0x7f, is three lists searched with `memchr()`.
- `0006` introduces one `quota_pkts` flag for credit counted per frame, which `0007` extends from
  commands to data; `mcu_quota_cmds` and `data_quota_pkts` are gone, and with them a second
  `pick_quota` call and an accumulator nothing read.
- The version 0 scan request: the 960-byte fixed length contradicted the trim to the end of the ies,
  which is what the vendor sends (226 bytes). The trim stays; the define and the guards on fields
  past the ies are gone. Flushed scans still 10 of 10.
- The part is known from its sdio id, `driver_data` on 0x7608, before the ownership handshake: the
  probe's forced reset, the RX1 queue and the resident-firmware reset now apply to it alone, and an
  MT7663S keeps mainline's `MISC2` path.
- Dead code out: owns-mac branches `IEEE80211_HW_TX_AMPDU_SETUP_IN_HW` made unreachable, a
  `sta_poll` drain nothing reached, the `mac_work` gate the functions already guard, unused defines,
  exports and parameters, `fw_data` (always `is_8023`), a second `MAX_TX_TIME`.
- `checkpatch.pl --strict`: sign-off only. 0010 went from 82 to 42 lines, 0011 from 1163 to 1115,
  0012 from 1127 to 1017.
- Both ways at once for 60 s on 5 GHz: 148-149 up and 5-7 down, where the build before the sweep had
  given 46 and 98. The backup from the start of the day now gives 146 and 9, against 113 and 28
  then: the access point, not the code. The vendor, the same hour: 132 and 19.

## 2026-09-25 — download starved by an upload

Backup replaced first: `.bak/2026-09-25-swept/`.

- With an upload running, a tcp download fell to 5-9 Mbit/s. UDP at 100 Mbit/s towards the box,
  under the same upload, arrived at 94.4 with 0.38% loss: receive has the bus and the air, and it is
  the download's acks that are held. A ping under upload took 27 ms.
- The data ring is 256 entries, 224 of them usable past `MT_TXQ_FREE_THR`, a fifo drained at the bus
  rate behind mac80211's fair queueing, ahead of the firmware's own 127. AQL does not bound it: its
  estimate is the 866 Mbit/s air rate, not the bus.
- Ring length against both ways at once for 20 s, 5 GHz, up and down: 256 gives 146/8; 128 gives
  120-143/12-36; 64 gives 97-119/32-56; 48 gives 77/72 but upload alone falls to 135; 32 leaves no
  room past `MT_TXQ_FREE_THR` and nothing is sent.
- 64 kept: 60 s both ways 112/42, upload alone 149, download 144, UDP 160, a ping under upload 8-11
  ms. The command ring keeps 256, which a firmware download needs: shrinking both fails the n9
  download with `-ENOSPC`.
- 2.4 GHz measured 91 up and 91 down: the access point now advertises no secondary channel, so
  channel 6 runs at 20 MHz, where it measured 137 and 116 at 40 MHz.

## 2026-09-25 — the series by responsibility, and an audit of what it carries

- The fourteen patches became six upstream ones, one per responsibility: the sdio core, the absent
  command op, the EEPROM file, the shared connac MCU code, mt7615's failure reports and semaphore
  wait, and the MT7668S. Nothing later rewrites what an earlier one added.
- The MT7668's code is its own: `mcu_ce.c` for the CE command space and `mac_ce.c` for the
  descriptor of a firmware that owns the mac, reached from mainline's `mt7615_mac_write_txwi()` by
  one early return. Its functions are `mt7668_`, as the MT7663's are `mt7663_`.
- A review of every hunk found three bugs: a leaked skb on every firmware debug message, on every
  mt7615 part; ciphers the firmware cannot take installed as none; random-address and scheduled
  scans advertised to a firmware that does neither.
- Removed as dead, each shown unreachable: the debug-message handler and its CE log fallback, seven
  absent-list entries this part never sends, the RAM image loader (mainline's does it, with its
  default chunk), the peer lookup in `tx`, our own `ENCAP_ENABLED`, the rx-queue guard, the `chfreq`
  invention, and the band-1, power-save and BIP branches of the descriptor.
- Removed on the others' behalf: the mailbox-miss latch and the one-second register timeout, both
  for a firmware death the credit fix no longer causes, which changed the MT7663S and MT7921S too.
  Credit polling, the a-msdu pn flags and the unload power-down are gated to this part.
- Ablated on the box, each against a gate of joins on both bands, reconnects, flushed scans,
  post-join replies, throughput and both-ways fairness:
  - removed, no measured effect: the join's leading deactivate, drop, `INFRASTRUCTURE` and abort-pm;
    the association's `SET_BSS_CONNECTED` and separate RLM message; the data credit cap; the
    probe-time forced reset. Five unload and reload cycles without cycling the host join each time.
  - kept, measured: `BASIC_CONFIG` and `SET_DBDC` - without them 5 of 10 reconnects time out the
    handshake against 1-2; `KEEP_FULL_PWR` with the PS profile - without them 9 of 20 time out and
    an idle ping peaks at 584 ms; the global wcid for a frame with no station - without it 4 of 10.
  - kept, reasoned: the guards on mac register reads, which this firmware does not answer and each
    of which costs the full MCU timeout.
- Before and after: 5 GHz 151 up and 144 down; the patches are 1980 lines for the MT7668S where they
  were 2160, and 113 for the sdio core where they were 164.
- Open: even the full sequence times out the handshake on 1-2 of 10 live reconnects, 15 s each.
- The box stopped answering twice during a module build on the box itself, the first time with two
  builds running. No oops reached pstore; the journal is on a RAM disk and lost everything past the
  last flush.

## 2026-09-25 evening — the reconnect timeouts, and what they were hiding

- The 1-2 of 10 live reconnects that timed out the handshake were one fault. The firmware reported
  every lost 2/4 as a queue timeout with a transmit count of zero: sent as an 802.11 command on the
  mcu port, EAPOL aged out of its queue without an attempt. The vendor sends it as an ethernet frame
  on the data path; converting it to 802.3 in the driver made 40 of 40 reconnect in 1 s.
- That confounded the earlier ablations. Retested against the fix, each of `BASIC_CONFIG`,
  `SET_DBDC`, `KEEP_FULL_PWR`, the PS profile, the drain after a CE command and the global wcid for
  a frame with no station changes nothing: reconnects, the gate and the idle ping are the same with
  all six gone. All six are removed.
- The receive path's cipher-header re-insertion, `ALLOW_SAME_PN` and `AMSDU_MORE` were a workaround
  for a descriptor that turned out to mark a-msdu subframes first and last correctly. Without them
  mt76 checks the PN once per a-msdu, and 5 GHz download went from 142-144 to 150-151 - the 5% the
  vendor had. The VHT 11454 MPDU length and beamformee the vendor advertises gained nothing on top.
- Benchmarked against the vendor on both bands, with `US` and with no domain set: level everywhere,
  and the domain changes nothing, because mt76 adopts the access point's country and the vendor runs
  its own. Numbers in `board.md`.
- The vendor series did not match the box: `0003` duplicated a hunk of `0002` and failed to apply,
  the box ran without `0009`, the 6.18 build fixes for the wi-fi half were in no patch, and nine
  debug prints were in the tree. Rebuilt from upstream `70b09b6` plus the series, which now applies
  in order with no fuzz and reproduces the built tree; the band clamp in `cnm.c` was dropped, the
  todo having recorded it as no difference.
- A patch disassociating the firmware on unload was written and dropped: cfg80211 already
  disconnects the interface when it goes away, and a reload after an association rejoined in 1 s
  without it.
- The box oopsed twice. The test scripts had hidden a failed `rmmod` of the vendor module, so the
  sdio host was cycled with it loaded. An IPv6 notifier unregistered on the wrong chain looked like
  the cause and was not compiled in. netconsole to a LAN host caught the trace the journal lost:
  `wiphy_update_regulatory` walking a wiphy the vendor's re-probe had freed while still registered.
  `0010` unregisters it; three rounds of the same sequence leave no wiphy behind and no oops.
- Also fixed in the vendor series: its p2p interfaces set their address behind the core's back,
  which warned on every unload (`0007`).

## 2026-09-25 night — the series reworked for review

- Two maintainer-style reviews of the series against mainline. Removed on the first: the core hook
  that swallowed commands a firmware lacks (replaced by an `mt7615_mcu_ops` table and explicit
  checks at each caller), the driver setting `HW_80211_ENCAP` on 802.11 frames (EAPOL now goes to
  the lmac port as 802.11), and the receive path's cipher-header re-insertion. Block ack sessions
  now go through mac80211's offloaded-session calls.
- Removing the command hook exposed one command it had been hiding: GTK rekey offload, sent after
  every handshake, which this firmware never answers. Each reconnect then waited out a 20 s MCU
  timeout. The gate missed it because `rc.sh` counted loop iterations, not time; it now reports
  milliseconds and MCU timeouts, and an exercise script drives every user-reachable control.
- The build harness reused stale objects: `rsync -a` kept each source's timestamp, so a file
  switched back to an older version stayed older than its object and was not rebuilt. Every A/B
  after the first variant of a batch was contaminated - the credit-polling removal leaked into the
  later runs, which is what made them lose pings. Builds now sync without timestamps, delete the old
  modules first, and stop on a failed build; the affected runs were repeated.
- Kept, measured: credit polling (without it 41 of the first 50 pings after a join are lost).
  Dropped, measured as no effect: `SET_DBDC`, the `reg_rr` error fix, and the hard-coded WPA2/CCMP
  in the bss record - the firmware ignores both fields.
- The second review found that TX completion stripped a fixed 64 bytes from frames that carry 32 or
  76, so every TX status mac80211 saw read the wrong header. Fixed; all 22 EAPOL statuses in a
  reconnect run now come back acknowledged. Also from it: the association sent commands without the
  device mutex, dual-band scans were silently full scans ignoring the regulatory channel list, and
  the transmit budget was rewritten under a running worker.
- The series is 11 patches plus the DKMS glue, each with a sign-off, clean under
  `checkpatch --strict`, and reproducing the tested tree. Every cumulative stage builds at `W=1`
  with no warning.

## 2026-09-26 — the forced reset removed

- The `WSICR` forced reset had three callers and no measured effect: the probe-time one was already
  ablated, and after it `WCIR_WLAN_READY` stays set, so it brings nothing back. Removed; a resident
  firmware now fails the probe with `firmware is still resident`, and an unload that does not power
  down warns and carries on.
- Five unload and reload cycles without cycling the host join in 4 s each, with no warning.
- The gate's both-ways leg dipped to 13-19 down on both the new and the previous build in the same
  hour, and passed on the next runs of each: 130/20 and 131/20 on the new one. Air, not the change.

## 2026-09-26 — the firmware payload trimmed to what is read

- `mt7668pr2h.bin` in the payload was a copy of `mt7668_patch_e2_hdr.bin`, and it overwrote
  `firmware-mediatek`'s genuine 170990-byte file: `/lib/firmware` is `/usr/lib/firmware` here.
  Dropped; the package provides it.
- `BT_RAM_CODE_MT7668_1_1_hdr.bin` is not requested: `btmtksdio` builds that name only for `0x7921`.
  Dropped.
- `mt7668_patch_e1_hdr.bin` and `TxPwrLimit_MT76x8.dat` are the vendor driver's alone, which is not
  shipped. Dropped; `stock/h96max-m20/firmware/` keeps them.
