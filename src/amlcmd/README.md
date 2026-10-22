# amlcmd — an Amlogic box over its OTG port

## Why

Linux on an Amlogic box usually starts from an SD card: write it, insert it, boot. A box with no
card slot has no such path; what is left is the OTG port and a serial console behind the case.

`amlcmd` takes the OTG port, from a Mac or a Linux host: back up and restore the whole eMMC, read
and write the environment, run any U-Boot command. One USB cable, the case closed, no serial.
Amlogic's own tool for this protocol is closed and runs on Windows or x86-64 Linux only.

It speaks U-Boot's burning gadget — the Amlogic analogue of Rockchip maskrom — and the mask ROM
behind it, in one C file against libusb.

## Install

On the host:

```sh
./build-amltools.sh          # needs libusb and OpenSSL
```

❓ Only macOS has run it so far.

Linux needs write access to the device, as root or with a rule:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", MODE="0660", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/70-amlogic-usbburn.rules
sudo udevadm control --reload
```

The procedure, entering the gadget, backup, restore, the mask ROM and recovering, is
`docs/amlogic-burning-mode.md`; this page is the tool.

## Verbs, and everything else

`amlcmd`'s verbs do what one command on the box cannot — drive the host's side of a transfer, or
loop over one:

| Verb                 | Issues on the box                           |
| -------------------- | ------------------------------------------- |
| `connect` `status`   | `AM_REQ_IDENTIFY_HOST`                      |
| `probe`              | `amlmmc size wholeDev`, `amlmmc read`       |
| `drain`              | nothing                                     |
| `read` `write`       | `upload`, `download`                        |
| `backup` `restore`   | `store disprotect key`, `amlmmc read/write` |
| `rom read/write/run` | nothing — the mask ROM                      |

Anything else goes to the box verbatim, a burning command or else a U-Boot one:

```sh
amlcmd printenv bootcmd
amlcmd setenv usb_on usb start 0
amlcmd reset
```

- A command is at most 63 bytes.
- Arguments are joined with spaces, so the shell's quotes do not survive and U-Boot splits at `;`.
- `amlcmd read` runs a transfer; `amlcmd upload` only arms one that nothing reads.
- A bare `failed:` means the handler put its reason on the UART.

## Porting to another board

```sh
amlcmd connect
amlcmd probe                                                   # what this box needs
AML_MMC_DEV=0 AML_STAGE_ADDR=0x10000000 amlcmd backup emmc.img # what it could not find
amlcmd backup probe.img 0 8                                    # prove it before anything writes
```

`probe` names the gadget, sizes the boot device, checks the staging address reads back, and picks
the eMMC out. `backup` and `restore` run the same discovery when `AML_MMC_DEV` is unset; a restore
stops rather than guess. On the M20 it finds the 30777344-sector eMMC at dev 1.

| Value               | Default           | Set it when                         |
| ------------------- | ----------------- | ----------------------------------- |
| `AML_MMC_DEV`       | discovered        | two devices answer alike, or none   |
| `AML_STAGE_ADDR`    | `0x20000000`      | `probe` says it does not read back  |
| `AML_WINDOW_MIB`    | `32`              | DRAM is tight                       |
| `AML_VID` `AML_PID` | `0x1b8e` `0xc003` | the vendor scan finds the wrong one |
| `AML_MODE`          | identify decides  | `probe` names the wrong gadget      |

Discovery can reject a staging address but not find one: a write outside DRAM wedges the box. Pick
mid-DRAM, above the gadget's buffers at `0x07700000`: `0x20000000` for 1 GB and up, `0x10000000` for
512 MB.

Measured on one board only, and possibly that U-Boot build's rather than the family's: the first
command loses four bytes (`connect` spends it), `md` resets the box, and `usb start` aborts while
the gadget runs.

## Known gaps

- A second process holding the gadget makes every other one fail with
  `claim interface: Access denied`, and can hang one mid-command.

## The protocol, as measured

| Request           | Transfer                     | Notes                                     |
| ----------------- | ---------------------------- | ----------------------------------------- |
| `TPL_CMD` `0x30`  | control OUT, 64 B, wIndex 1  | wIndex 0 is accepted and silently ignored |
| `TPL_STAT` `0x31` | control IN, 64 B             | verdict at `[0:7]`, detail after; not 512 |
| `UPLOAD` `0x33`   | control IN, 16 B             | arms bulk IN `0x81`; 64 KiB chunks        |
| `DOWNLOAD` `0x32` | control OUT, 32 B, wIndex -1 | data on `0x02`, verdict back on `0x81`    |
| `IDENTIFY` `0x20` | control IN, 8 B              | within 750 ms, or the box resumes booting |

- `UPLOAD`'s header is magic `0xefe8` and the next chunk's length, zero when done.
- `DOWNLOAD`'s header is resent flag, length, sequence from 1, the add-sum of the chunk's 32-bit
  words, and `ackLen << 16 | 0xef`.
- `upload store` needs `disk_initial 0` first, even though that answers `failed:`.
- Bulk IN takes whole 512-byte packets; bulk OUT at most 4096 bytes per call.
- Claim the interface before any bulk transfer, and release it before exiting.

## Dead ends

- `AM_REQ_RD_LARGE_MEM` (`0x12`) to fetch upload data: wedges the gadget.
- `AM_REQ_BULKCMD` (`0x34`) for commands: its 512-byte reply desynchronises the next transfer.
- A bare `update` to park the box: kills the reply channel.
- Keepalives: identify at connect is what holds the link.
- `md` to read memory: resets the box. `read mem` instead.
- `get_chipid`: not built into this U-Boot.
- A console over USB: command status crosses USB, command output only leaves by the UART.
