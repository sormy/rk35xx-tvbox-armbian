# Where the Bluetooth firmware is, and why it cannot be patched

Asked: decompile the BT firmware, map it, find where to add wake filtering. The answer is that the
BT controller code is **not host-loadable** — there is no image to decompile.

## What the chip is actually given

The driver downloads four things, and none is Bluetooth code:

- `SWT6621S_IRAM_SDIO.bin`, 358 776 B — the CP code image
- `SWT6621S_DRAM_SDIO.bin`, 192 816 B — data, no code strings at all
- `SWT6621S_SEEKWAVE_R00001.bin` — RF calibration
- `sv6160lite.nvbin`, **37 bytes** — BT NV, header `NVDS`. Configuration, not firmware

`btseekwave_download_nv()` is the only thing the BT driver ever sends, and it sends that 37-byte NV
blob. The platform side (`skw_boot.c`) downloads IRAM and DRAM. There is no BT code path.

## The IRAM image is Wi-Fi

Raw Cortex-M, no header, load address `0x00100000`:

```
00000000: 687f 1000 2547 1000 f540 1000 f540 1000
          SP=0x00107f68  reset=0x00104725 (Thumb)
```

648 printable strings, uncompressed. Every source path in it is one subsystem:

```
../../../../connectivity/wifi/     ×10 distinct paths
connectivity/wifi                  — the only top-level subsystem present
```

Modules named inside: `pm_arb_wrap`, `wifi_schedule`, `hal_mac_isr`, `hal_mac_tx/rx/comm`,
`machw_com`, `blockack`, `adpt_cmd`, `hif`, `hif_rx`, `hif_tx`, `inst_mgmt`, `npi_mac`, `pm_sta`,
`pm_dynamic_ps`, `scan`, `peer_mgmt`, `sta_sm`, `chan_switch`, `ap_ctrl`, plus SDIO slave drivers
(`sdio_slv_drv`, `sdio_slv_channel_drv`, `sdio_slv_phy_v2p0`, `dma_drv`, `timer_phy_v0`).

**The only Bluetooth string in the whole image is `sdio_slv_bt_drv.c`** — the SDIO slave _transport_
that carries BT traffic between host and chip. Not a link controller, not an HCI layer.

## The proof it is in ROM

The assert that forced the firmware swap is `BSPASSERT:hci_tl.c-386`, sent by the chip over the
LOOPCHECK channel. That string appears in **none** of the blobs — grepped across every image in
`stock/*/firmware/` and `firmware/common/seekwave-fw/` for `hci_tl`, `hci_`, `lmp`, `bt_ll`,
`le_ll`: one hit total, and it is `sdio_slv_bt_drv.c`.

So `hci_tl.c` is compiled into code the host never supplies. The BT stack — HCI command handling,
the link layer, and whatever decides to assert the host-wake GPIO — lives in on-chip ROM.

## What this closes

Adding controller-side wake filtering would mean modifying that stack. We cannot:

- there is no image to decompile, so the Ghidra route used for the Wi-Fi TX latch bug has no input;
- `fwpatch.py` and the CRC-free download path are irrelevant, since the bytes we can patch are
  Wi-Fi;
- swapping to the factory images changes Wi-Fi code, not BT — which is consistent with the measured
  result that the firmware swap changed nothing about wake behaviour.

It also explains `LE_Get_Vendor_Capabilities` reporting `filtering_support = 0`: the capability is
absent from a ROM nobody can update, not from a configuration anyone can change.

## What could still be done with it

The IRAM image **is** patchable, and the Wi-Fi TX latch work proved the toolchain end to end. If a
future problem is in the Wi-Fi path, or in the SDIO transport shared with BT — `sdio_slv_bt_drv.c`
is in this image — that is reachable. Host-wake assertion for Bluetooth is not.

## The configuration surface, and why it does not help either

The BT stack is ROM, but its **configuration** is host-supplied, so it is worth knowing exactly what
is adjustable. The vendor ships a decoder for the NV format:
`stock/h96max-h313/firmware/SWT6621S_NV_SDIO.ini`.

`SWT6621S_NV_SDIO.bin` is 220 bytes with a 32-byte header of offset/size pairs:

```
RFCFG   offset 0x000000  size 0
CMCFG   offset 0x000020  size 28      <- everything configurable lives here
PINCFG  offset 0x000000  size 0
BTCFG   offset 0x000000  size 0       <- absent
```

`CMCFG` is `BSP_CFG0`, `BSP_CFG1`, `BSP_DCXO`, `BSP_CFG2`, then `BT[16]`, then `WIFI[8]`.

What `BSP_CFG0` controls, per the vendor's own comments:

- bit 0 `BT_ANTENNA_TYPE` — shared or stand-alone
- bit 1 `UART1_DTM` — switch HCI to UART1 for test mode
- bits 3:2 `USB_SPEED_TYPE`
- bit 4 `UART_LOG_ENABLE` — CP log to UART1
- bit 5 **`GPIO_WAKEHOST_VLD_LEVEL`** — 0 low-level valid, 1 high-level valid
- bit 6 `BUSMONITOR_STATE`
- bit 7 `DCXO_CFG_ENABLE`

`BT[0]` is `COEX_TYPE` (TDD / FDD / free-run). `BT[1..15]` are undocumented and **all zero** in both
shipped variants; the two variants differ only in `BSP_CFG0` bit 0 and `BT[0]`.

**No knob filters wakes.** `GPIO_WAKEHOST_VLD_LEVEL` sets the electrical level of the host-wake
signal, not the conditions under which the chip asserts it. Everything else is RF routing,
coexistence, USB speed or clock trim.

Two settings would be genuinely useful for understanding the ROM and are unreachable here:
`UART_LOG_ENABLE` would emit the chip's internal log, and `UART1_DTM` would route HCI over UART.
Both need a serial port, and this board has no designed serial pins.

The BT driver separately downloads `sv6160lite.nvbin`, 37 bytes with an `NVDS` header — BT NV, far
too small to hold behavioural configuration.

So configuration is adjustable, documented, and contains nothing that could filter a wake.
