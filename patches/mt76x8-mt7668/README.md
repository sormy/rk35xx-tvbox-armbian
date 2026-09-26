# MediaTek's MT7668 driver on 6.18

MediaTek's own driver, `wlan_mt76x8_sdio` and `bt_mt7668`, as the comparison and fallback for
mainline mt76. It is not shipped on the board.

The source is `https://github.com/LondyGhost/mt7668-armbian` at `70b09b6`, a port of the tree to
Armbian, driver version 2.0.0 - the same generation as the module in the box's vendor partition.

## The patches

| Patch  | Fixes                                                                |
| ------ | -------------------------------------------------------------------- |
| `0001` | the Bluetooth half's build on 6.18                                   |
| `0002` | the Wi-Fi half's build on 6.18                                       |
| `0003` | a fallback regulatory domain clamped to 0 dBm                        |
| `0004` | an empty channel list sent to the firmware, which stopped every join |
| `0005` | a deadlock setting the country from the regulatory notifier          |
| `0006` | FORTIFY_SOURCE warnings on the command buffers                       |
| `0007` | net device addresses written behind the core's back                  |
| `0008` | a kernel log full of state narration                                 |
| `0009` | firmware looked for outside `/lib/firmware/mediatek`                 |
| `0010` | a p2p wiphy freed while registered, which oopsed after a host cycle  |

The Wi-Fi patches apply in `MT7668-WiFi/drv_wlan/MT6632`, `0001` in `MT7668-Bluetooth`, all with
`patch -p1`, in order.

## Building it

On the box:

    cd MT7668-WiFi && make
    cd MT7668-Bluetooth && make KERNEL_SRC=/lib/modules/$(uname -r)/build ARCH=arm64

Beside mt76's firmware it takes two more factory files. From the host:

    scp stock/h96max-m20/firmware/{mt7668_patch_e1_hdr.bin,TxPwrLimit_MT76x8.dat} root@h96max-m20:/lib/firmware/mediatek/

## What it does that is not a fault

The factory Android log carries these on a box whose Wi-Fi worked:

    wlanQueryNicCapability: skip unexpected event ID[0x27]
    wlanAdapterStart: load manufacture data fail
    rlmDomainSearchRegdomainFromLocalDataBase: Cannot find the correct RegDomain. country = 00.

`load manufacture data fail` is an Android NVRAM partition this image does not have.

`iwpriv wlan0 driver "GET_CNM"` reports the channels currently granted, not the ones available:
`0 CHs` is correct for an interface that is not associated.

## Its country code

- It packs the country two ways: `wlanCfgSetCountryCode()` puts the first character in the high
  byte, `rlmDomainAlpha2ToU32()` in the low. They agree only on palindromes, which is why `00` works
  and `US` cannot.
- `Country` must be the literal `00` in `wifi.cfg`. The power table is matched against `0x3030`, and
  an unset country is `0x0000`, which misses the only table in `TxPwrLimit_MT76x8.dat` and reports 0
  dBm on every channel.

## Its Bluetooth

`bt_mt7668` probing while the Wi-Fi half initialises asserts the firmware's shared WMT task:
`<ASSERT> system/cos/cos_api_t.c #1005 ... id=0x0 WMT`. Mainline `btmtksdio`, with
`patches/btmtksdio-mt7668/`, runs alongside mt76 instead.
