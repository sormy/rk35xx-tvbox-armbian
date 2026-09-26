# Mainline mt76 for the MT7668S

Mainline's mt76 plus the MT7668S, built as DKMS. The part is an MT7663 sibling on SDIO - the same
register map, connac descriptors and firmware download - whose firmware owns the MAC.

`firmware/common/fetch-mt76-src.sh <dir>` stages the tree with these applied.

## The patches

| #    | Holds                                                      | Upstream |
| ---- | ---------------------------------------------------------- | -------- |
| 0001 | sdio: credit counted in frames, charged by port            | yes      |
| 0002 | sdio: a shorter data ring                                  | yes      |
| 0003 | sdio: credit polling on a host with no card interrupt      | yes      |
| 0004 | the EEPROM from a firmware file when there is no storage   | yes      |
| 0005 | connac: the version 0 scan request                         | yes      |
| 0006 | mt7615: wait out a held patch semaphore                    | yes      |
| 0007 | mt7615: a profile of what a part's firmware does           | yes      |
| 0008 | mt7615: the MT7668's CE commands and descriptor            | yes      |
| 0009 | mt7615: loading and resetting a firmware that owns the MAC | yes      |
| 0010 | mt7615: running a part whose firmware owns the MAC         | yes      |
| 0011 | mt7615: the MT7668S's sdio id and profile                  | yes      |
| 0012 | build the SDIO stack out of tree, over the in-tree modules | no       |

Each patch builds on its own at `W=1`. `cover-letter.txt` introduces the set for submission.

## What works

| Step                                | State                                |
| ----------------------------------- | ------------------------------------ |
| claims the part, loads its firmware | ✅                                   |
| `wlan0` registers and comes up      | ✅ with the unit's own fused address |
| scan returns results, repeatably    | ✅ both bands                        |
| authenticates and associates        | ✅ both bands                        |
| completes the four-way handshake    | ✅ `PTK=CCMP GTK=CCMP`               |
| reconnects without a reload         | ✅ in 105-352 ms, 40 of 40           |
| passes traffic both ways            | ✅ level with the vendor driver      |
| reloads after an association        | ✅ `rmmod` and `modprobe`            |

The numbers, per driver and regulatory domain, are in `docs/h96max-m20/board.md`.

The unload powers the firmware down and hands ownership back, which is what lets it reload. A part
left wedged - `Cannot get ownership from device` or `firmware is still resident` at probe - comes
back by cycling the sdio host:

    echo d0070000.sdio > /sys/bus/platform/drivers/meson-gx-mmc/unbind
    echo d0070000.sdio > /sys/bus/platform/drivers/meson-gx-mmc/bind

## Known gaps

| Gap                        | State                                                  |
| -------------------------- | ------------------------------------------------------ |
| AP, P2P, mesh              | not implemented; the firmware takes AP role commands   |
| Remain-on-channel          | 🟡 mac80211's software one; no channel-switch command  |
| System suspend             | ❓ sends the MT7663's HIF commands                     |
| AP channel switch (CSA)    | ❓ no channel-switch command; likely a reconnect       |
| Scan while associated      | 🟡 works, but 20 s for 28 BSSes; traffic during it ❓  |
| Both ways at once          | 🟡 13-19 down on some runs, ~30 on others; unexplained |
| Reconnect and roam time    | 🟡 two groups, ~110 and ~340 ms; unexplained           |
| Firmware in linux-firmware | not there: none of the four images                     |

AP is proven only as far as `hostapd` reaching `AP-ENABLED` on the vendor driver. Porting it needs
the beacon template, the BSS in AP role and client station records; remain-on-channel needs
`SET_ROC` with a general request type, which the join already sends.

## What it is called

| Axis                      | Value  | Where it shows                                                         |
| ------------------------- | ------ | ---------------------------------------------------------------------- |
| connectivity combo die    | MT6632 | the vendor source dir `drv_wlan/MT6632/`, `-DMT6632`, `chips/mt6632.c` |
| the wi-fi product         | MT7668 | `MT7668-WiFi/`, `chips/mt7668.c`, `WIFI_RAM_CODE_MT7668.bin`           |
| the vendor module         | 76x8   | `wlan_mt76x8_sdio.ko`, a wildcard over the family                      |
| the codebase it grew from | MT6620 | the header provenance, `MT6620_WIFI_DRIVER_V2_3`                       |

mt76 names parts by connac generation and register map, which is why a part sold as MT7668 and built
as MT6632 is driven from `mt7615`.

## What its firmware needs

- **Its ROM patch at `0xc8000`**, not the MT7663's `0xdc000`. Anywhere else the firmware asserts
  `!RB_FULL( (*q_id) ), id=0x2` on every boot.
- **Only the commands it has.** Its ext table stops at `0x4f`. A command it lacks draws silence,
  each one a 20 s MCU timeout, and some stop the commands after them being answered. Not sent:
  `ATE_CTRL 0x3d`, `PROTECT_CTRL 0x3e`, `DBDC_CTRL 0x45`, `MAC_INIT_CTRL 0x46`, `RX_HDR_TRANS 0x47`,
  `MUAR_UPDATE 0x48`, `BCN_OFFLOAD 0x49`, `SET_RX_PATH 0x4e`, `TX_POWER_FEATURE_CTRL 0x58`,
  `RXDCOC_CAL 0x59`, `TXDPD_CAL 0x60`, `CAL_CACHE 0x67`, `SET_RADAR_TH 0x7c`,
  `SET_RDD_PATTERN 0x7d`, `PM_STATE_CTRL 0x07`, CE `SET_RATE_TX_POWER 0x5d` and the scheduled scan
  pair, and uni `OFFLOAD 0x06` - the ARP filter and GTK rekey offload.
- **Its registers left alone.** Every register access is an MCU round trip that races the commands;
  `MT_WF_RMAC_MIB_AIRTIME0`, `MT_WF_PFCR`, `MT_WF_MIB_SCR0`, `MT_WF_PHY_WF2_RFCTRL0`,
  `MT_WTBL_UPDATE` and `MT_CHFREQ` never answer. MAC and PHY init, statistics, survey, airtime and
  rate-table reads, and the `RFCR` filter writes are skipped.
- **The version 0 scan request**, ending at the ies: 282 bytes on the wire. The version 1 form stops
  it answering after the first scan. It lists 32 channels, so each band is its own request.
- **The BSS up before a scan**, since it probes from it: down, a flushed full scan found the access
  point 2 times in 10, up 10 of 10.
- **A 32-byte descriptor for every frame.** The ninth word mainline writes for a bus that is not
  mmio lands on the frame's own header.
- **Data on the lmac port, management on the mcu port.** Data comes from mac80211's transmit
  encapsulation offload as ethernet and the firmware builds the 802.11 header; 802.1X goes to the
  lmac port too, since on the mcu port it aged out unsent. Management without a rate from mac80211
  goes at the band's lowest basic rate.
- **A 44-byte append on every lmac frame**, from which the firmware reads the bss index. Without it:
  `<CR4>Warning: ucBssIndex > CFG_BSS_NUM. Drop it.`
- **The retry count and lifetime in the descriptor**: 30 tries, 2 s. The host rate table that would
  supply the count is never populated.
- **A default rate code** in the station record and the bss: without it 13 of 33 frames aged out
  unsent, against 3.
- **Its credit counted in frames.** Command credit returns on TQ15, data credit on TQ0-TQ11, one per
  frame, with no PLE pool. A frame is charged by the port bit in its descriptor: a management frame
  sent through a data queue lands in the seven-deep command queue, and charged to the data pool it
  overran that queue until the firmware asserted in `nic.c #2431`. Data sits on TC1's 167 buffers.
- **Block ack left to it.** mac80211 is told it sets up transmit sessions itself: an ADDBA mac80211
  sends is never transmitted and stalls the tid. Its `EVENT_RX_ADDBA` and `EVENT_RX_DELBA` drive
  mac80211's offloaded receive sessions.
- **The BSS as the own-mac index and the first WMM set.** The bss, its EDCA table and a descriptor's
  queue name one set; the EDCA command takes BE, BK, VI, VO.
- **Table entries 1-2 left to it.** A peer gets entry 3.
- **Its receive filter set by command**: `0x0a` with directed, multicast, all-multicast and
  broadcast.
- **Receive header translation off.** mac80211 takes an 802.3 frame only after the handshake.
- **Keys by command**, `0x07`: the pairwise key into the peer's entry, the group key into entry 0.
- **A connection through the CE commands.** Join: `0x12` disconnected, `0x14` dropping every station
  of the bss, `0x11`, `0x1c`, `0x13` at state 1. Association: `0x12` connected, `0x13` at state 3,
  `0x0a`. Leave: abort-pm, `0x12`, `0x14`, `0x11` off, the channel handed back. The ext
  `STA_REC_UPDATE`, `BSS_INFO_UPDATE` and `DEV_INFO_UPDATE` draw silence, and a station removed by
  index leaves every later scan unfinished.
- **The channel granted before a join.** `0x1c` asks; `MCU_EVENT_ROC 0x10` grants in about 34 ms.
  Without it the first frames age out unsent.
- **The peer's VHT operating mode in the station record.** Left at 0, the firmware transmits at 20
  MHz on one stream: `0x12` on an 80 MHz two-stream link. The width also goes in the channel request
  and the bss.
- **No country power table.** `0x49` draws 1032 complaints: mt76's limits sit above its efuse's.
- **Its log in the CE space.** `MCU_CE_CMD(FWLOG_2_HOST) 0xc5`, reported as
  `MCU_EVENT_DBG_MSG 0x27`; `echo 1 > /sys/kernel/debug/ieee80211/phy*/mt76/fw_debug` turns it on.
  It names every command it receives: `HEM: CMD_ID:0x03 SEQ:15 LEN:992`.
- **An ethernet frame flagged at `BIT(12)` of `TXD1`**, unnamed on connac1: directly below
  `MT_TXD1_HDR_FORMAT`, where connac2 puts its `MT_TXD1_ETH_802_3`.

## Not the cause

Measured and reverted:

- preserving the rx bits a mailbox poll takes from the read-clear `WHISR`
- pacing the firmware download, or draining the queue between slices
- taking the rx length from `WRPLR` rather than the status block
- a sequence number only for commands that draw a reply
- rewriting `WHCR` and `WHIER` at probe
- restarting a resident firmware before loading, or a forced reset through `WSICR`: `WCIR` stays set
- waiting for an acknowledgement of `REG_WRITE`, which never comes
- caching registers that fail to answer, which marks good ones dead once the part is busy
- for unicast loss: software crypto, marking the pn validated, dropping `0x16`, `0x19` and `0x0a`,
  the sdio scheduler's quotas, reverse path filtering, frame length from 1 to 1200 bytes

## Measuring

- **Unload every module, youngest first**, before loading a new build. `modprobe -r mt7663s` leaves
  `mt7615_common`, which holds nearly every line these patches change:

      for m in mt7663s mt7663_usb_sdio_common mt76_sdio mt7615_common mt76_connac_lib mt76; do rmmod $m; done

- **A three-run batch resolves only large effects.** Answered pings swung from 0 to 6 of 20 between
  fresh associations of one build; transmit status breakdowns, `tx retries` and the scheduler quotas
  move by factors.
- **Monitor mode cannot see this station's own transmissions.** Seeing them needs a second radio.

## Building it

    firmware/common/fetch-mt76-src.sh /tmp/mt76
    make -C /lib/modules/$(uname -r)/build M=/tmp/mt76 modules \
      CONFIG_MT76_CORE=m CONFIG_MT76_SDIO=m CONFIG_MT76_CONNAC_LIB=m \
      CONFIG_MT7615_COMMON=m CONFIG_MT7663S=m CONFIG_MT7663_USB_SDIO_COMMON=m

The part needs `mediatek/mt7668_patch_e2_hdr.bin`, `mediatek/WIFI_RAM_CODE_MT7668.bin`,
`mediatek/WIFI_RAM_CODE2_SDIO_MT7668.bin` and `mediatek/EEPROM_MT7668.bin`.
