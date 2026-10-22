# Pinning MAC addresses: userspace is the wrong layer

On TVBian `mac-pin` is gone: no box runs it since 2026-10-20, each address from U-Boot or its
driver. It stays in `firmware/common/` until the overlay goes.

Family-wide. Opened 2026-09-06, after `rk35xx-mac-pin` turned out to be the single largest cost in
the H96 Max 3518D's boot — 12.6 s of a 19.7 s userspace, and 2.0 s even once fixed.

## What we do now, and what it costs

`rk35xx-mac-pin` is a oneshot unit that waits for each interface to appear, then
`ip link set <if> address <derived>`. It works, and it is the slowest layer available:

- **It runs after the interface already exists**, so the NIC is up with the wrong address for a
  window. Anything that reads the address in that window — DHCP, an early daemon — sees the old one.
- **It waits.** The wait is 50 × 0.2 s per interface, and an interface that never appears costs the
  full 10 s. On the 3518D that was `end0`, listed in `mac-oui` on a board with no ethernet PHY;
  removing the line took boot from 24.0 s to 13.6 s. Correct board data hides the problem without
  removing it.
- **It is per-interface serial**, so the cost scales with how many interfaces a board lists.

## The contract has four ids; we consume three

Rockchip vendor storage defines `1 SN`, `2 WIFI_MAC`, `3 LAN_MAC`, `4 BT_MAC`, and
`rk35xx-vendor-storage` reads all four. `rk35xx-mac-pin` maps only `end0|eth*` to `lan` and `wlan*`
to `wifi`; nothing in the repo sets a Bluetooth `BD_ADDR`, so id 4 has no consumer at all.

Unpopulated on the three boxes dumped so far, which is why it has not bitten — the controller
invents a `BD_ADDR` each boot, and a wandering one invalidates every pairing. That is data about
those units, not a property of the platform: a unit carrying `BT_MAC` would be ignored today.
Whatever replaces `mac-pin` should consume the contract, not the two ids these boards happen to
populate.

## Below userspace

An overlay box could not ship kernel patches; TVBian's kernel does, so each address is set before
the interface exists.

| Interface      | Source, then fallback             | Patch                              |
| -------------- | --------------------------------- | ---------------------------------- |
| Ethernet       | vendor storage `LAN_MAC`, `cpuid` | U-Boot `0003`: `local-mac-address` |
| AIC8800 Wi-Fi  | `WIFI_MAC`, efuse, SoC's OTP id   | `patches/aic8800/99-stable-mac`    |
| Seekwave Wi-Fi | `WIFI_MAC`, then the chip's efuse | none needed: the driver reads both |
| MT7668 Wi-Fi   | the chip's firmware               | none needed                        |
| Seekwave BT    | the chip: its efuse address + 1   | none needed                        |
| AIC8800 BT     | the tree, efuse, then Wi-Fi + 1   | `bluetooth-hci-h4-aic8800-bdaddr`  |
| Bluetooth      | `BT_MAC`, then the SoC's OTP id   | per driver, not written            |

Ethernet is set in U-Boot because the kernel cannot read the store on every series: 6.12 dropped
`sdmmc_vendor_storage`, leaving only the flash, MTD and RAM backends. The radios stay in their
drivers, which ask their own firmware. The four vendor-storage ids are the contract, so a unit
carrying `BT_MAC` is honoured though none dumped here does.

A derived address changes once on migration: the drivers' OTP-id rule is not `mac-pin`'s `sha256` of
cpuid and interface. DHCP reservations and Bluetooth pairings follow it.

## The alternatives

**A systemd `.link` file, generated once.** `net_setup_link` applies it as the device appears, which
is earlier than any unit can run and has no wait at all. The catch, already recorded in `AGENTS.md`:
`.link` takes a **literal** address, so a derived one has to be written into a generated file at
first boot rather than computed at event time. That makes first boot slightly more complex and every
subsequent boot free.

**The kernel reads it, from the tree alone.** A `mac-address` nvmem cell on the gmac node is read by
`of_get_mac_address()` at probe, no userspace at all. Two sources:

- the OTP: ❓ if the RK3528's holds a MAC rather than only the `cpuid` U-Boot derives one from;
- vendor storage: not in mainline 6.18, where only MTD registers an nvmem provider — none on a block
  device — and no layout parses `DVKR`'s tag table; both would be new kernel code.

**Upstream, later: a vendor-storage nvmem layout.** "Support for block device NVMEM providers" (v10,
2026-08) lets an eMMC partition node carry an nvmem layout; its bindings are in v7.3-rc1, the block
provider itself is reviewed but not yet applied. On top of it, a small layout driver in the shape of
`onie-tlv` would parse `DVKR` — newest valid copy, tag table — into `mac-address`, Wi-Fi and
`local-bd-address` cells for each board's tree to point at. It reaches these boards once our kernel
carries it.

## The measurement that motivated this

| Boot phase             | Before | After removing a phantom `end0` |
| ---------------------- | ------ | ------------------------------- |
| kernel                 | 4.2 s  | 4.2 s                           |
| userspace              | 19.8 s | **9.4 s**                       |
| `rk35xx-mac-pin` alone | 12.6 s | **2.0 s**                       |

2.0 s is still the second-largest unit on the box, and all of it is waiting for an interface that
the kernel is about to create anyway.

## Why a vendor driver ignores vendor storage

- `CONFIG_WIFI_GENERATE_RANDOM_MAC_ADDR` generates an address once and persists it with
  `rk_vendor_write()`; if that write fails — an uninitialised or read-only vendor storage partition
  will do it — the driver silently generates a fresh one every boot.
- Before blaming that write, check the driver reaches the code at all. The symbol only gates
  `get_wifi_addr_vendor()` in `net/rfkill/rfkill-wlan.c`, which a Wi-Fi driver must opt into by
  calling `rockchip_wifi_mac_addr()`. Vendored SDIO drivers routinely hide that behind their own
  `CONFIG_PLATFORM_*` knobs and then ask the firmware, which invents one per boot.
  `grep -c rfkill-wlan` over a boot log settles it: zero means vendor storage is not the problem.

## The Seekwave chip carries its own address

The H313's factory Android boot: `skw_sync_chip_info: efuse mac: fe:fd:fc:99:08:5f, valid`, the same
as Armbian's `phy0` permanent address, and Bluetooth `FE:FD:FC:99:08:60`, one above it.
`skw_drv_probe`'s `MAC: 00:00:00:00:00:00` is only the unset module parameter. The driver takes
`skw_mac`, then vendor storage's `WIFI_MAC`, then the efuse, so on this chip `mac-pin` only ever
overrode a stable factory address; without it `wlan0` comes up as the factory's.
