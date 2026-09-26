# MT7668 SDIO host protocol

Reverse engineered from the vendor driver that works on this board (`wlan_mt76x8_sdio` 2.0.0, the
module in the box's own vendor partition), so that mainline's `mt7663s` can be compared against it
line by line. Register values marked measured were read back off the part.

## Registers

| Addr   | Name     | Fields                                                                                                                           |
| ------ | -------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 0x0000 | WCIR     | chip id in the low 16 bits; `WLAN_READY` = BIT(21)                                                                               |
| 0x0004 | WHLPCR   | `INT_EN_SET` BIT(0), `INT_EN_CLR` BIT(1), `FW_OWN_REQ_SET` BIT(8), `FW_OWN_REQ_CLR` BIT(9); reads back `IS_DRIVER_OWN` in BIT(8) |
| 0x0008 | WSDIOCSR |                                                                                                                                  |
| 0x000C | WHCR     | `W_INT_CLR_CTRL` BIT(1), `RECV_MAILBOX_RD_CLR_EN` BIT(2), `MAX_HIF_RX_LEN_NUM` bits 8-13, `RX_ENHANCE_MODE` BIT(16)              |
| 0x0010 | WHISR    | interrupt status, clears on read                                                                                                 |
| 0x0014 | WHIER    | `TX_DONE` BIT(0), `RX0_DONE` BIT(1), `RX1_DONE` BIT(2), `ABNORMAL` BIT(6), `FW_OWN_BACK` BIT(7), `D2H_SW_INT` bits 8-31          |
| 0x0024 | WSICR    | software interrupt control                                                                                                       |
| 0x0034 | WTDR1    | tx data port                                                                                                                     |
| 0x0050 | WRDR0    | rx data port 0                                                                                                                   |
| 0x0054 | WRDR1    | rx data port 1                                                                                                                   |
| 0x0154 | SWPCDBGR | firmware program counter                                                                                                         |

`MAX_HIF_RX_LEN_NUM` holds 0..15, where **0 means unlimited**. The vendor's setter converts any
value >= 16 to 0, so 16 is never written.

Measured after the vendor driver initialises: `WHCR 0x00010000`, `WHIER 0xffffff47`,
`WHLPCR 0x00000100`. SDIO block size 512, status block 112 bytes.

## Access rules

- **WHCR is read-modify-write.** The vendor never writes it blind.
- **WHLPCR interrupt enable/disable is a byte write.** A 32-bit write is used only where the
  ownership bits in byte 1 are deliberately being set.
- **Port reads and writes are rounded up to whole SDIO blocks** and issued in block mode. Below one
  block the vendor's port read issues **no bus access at all** - with a 512-byte block that is true
  of any read shorter than 512 bytes, the 112-byte status block included.

## Status acquisition

Two modes, and which one is in force changes where the status comes from:

| Mode                       | Where the status block comes from                                        |
| -------------------------- | ------------------------------------------------------------------------ |
| plain                      | read WHISR                                                               |
| `RX_ENHANCE_MODE` (vendor) | appended to every rx **data** port read, after the data and a 4-byte pad |

In enhanced mode the driver takes the last 112 bytes of each rx read as the new status, copies it
into its cached copy, and sets a pending flag so the next status query uses the cache instead of
touching the bus. There is therefore no separate status read at all, which is consistent with the
port read declining to issue one.

## Status block, 112 bytes

    u32 WHISR
    u32 WTSR[8]                     tx released counts
    u16 NumValidRx0Len, NumValidRx1Len
    u16 Rx0Len[16], Rx1Len[16]
    u32 RcvMailbox0, RcvMailbox1

## The status bits are advisory, the counters are authoritative

The vendor **synthesises** bits the hardware left clear: if any `WTSR` entry is non-zero while
`WHISR_TX_DONE_INT` is clear, it sets that bit itself, and likewise for the mailbox bit. A populated
counter beside a clear done bit is therefore an expected state on this part, not a contradiction.

## Ownership

Request driver ownership by writing `FW_OWN_REQ_CLR` to WHLPCR, then poll until `IS_DRIVER_OWN`
reads back. Firmware ownership is requested with `FW_OWN_REQ_SET`.

## Interrupts

`WHIER = 0xffffff47` - rx0, rx1, tx, abnormal and the whole D2H software interrupt range. The driver
is purely interrupt driven: its three kthreads all wait without a timeout, so nothing polls.
