# amlcmd — worklog

Dated history, wrong turns included. Built against an H96 Max M20 (S905L3, platform `p291`); "this
box" below is that one.

## 2026-09-15 — the OTG gadget is U-Boot's, not the ROM's

`pyamlboot` cannot drive this box. With the button held through a power-cycle the OTG port
enumerates `1b8e:c003` and answers `REQ_IDENTIFY_HOST` with `ROM: 0.7 Stage: 0.16`, but every memory
read fails — `0xd9000000` (`DDR_LOAD`) and `0xd900c000` (`BL2_PARAMS`), the GX addresses pyamlboot
uses for this family, both `USBError`. Identify without memory access is the v2 burning gadget.

That follows from the box working: the ROM only enters USB Boot mode when it cannot load BL2 from
eMMC. The button reaches `upgrade_sadckey` -> `run update` -> `usb_burning=update 1000`, which is a
U-Boot gadget by construction, so no button press can ever produce ROM mode here.

**A first probe reported the same verdict for the wrong reason** and should not have been trusted:
it tested `readSimpleMemory` at `0xd9040000`, an AXG/G12-era SRAM address. The read failed because
the address was wrong for GX, not because the protocol was absent. The verdict only became evidence
once the GX addresses from pyamlboot's own parameters were tried and failed too.

Consequence: backup and restore go through the SD card, not a host tool. Once `aml_autoscript` boots
a kernel, the eMMC is a plain block device and `dd` is symmetric. `pyamlboot` keeps one role — the
unbrick path, reachable only by stopping the ROM from finding a loader, which is the honest analogue
of maskrom on these boards.

### `set_usb_boot 2` reaches ROM USB Boot mode — pyamlboot works after all

The vendor U-Boot carries `set_usb_boot`, whose own usage lists `1: CLEAR_USB_BOOT`,
`2: FORCE_USB_BOOT`, `3: RUN_COMD_USB_BOOT`, `4: PANIC_DUMP_USB_BOOT`. `set_usb_boot 2` prints
`usb flag: 2`; the following `reset` runs BL1 and BL2 as far as `Skip usb!` and stops there. That
line is the marker that the flag took.

The box then enumerates `1b8e:c003` and **stays enumerated** — no 8-second window — and this time
the boot protocol answers:

```
identify raw=0204000000010000   ROM: 2.4  Stage: 0.0
read DDR_LOAD   0xd9000000 -> 0eb0b6f51e76fec6b4dd546b23488358
read BL2_PARAMS 0xd900c000 -> e6160b45c0d2a0d3e54efa851241b9ad
```

`identify()` alone separates the two gadgets: ROM 2.4 / Stage 0.0 is the mask ROM, ROM 0.7 / Stage
0.16 is U-Boot's burning mode. Worth keeping, because both present the same USB ids.

Those 16 bytes from `0xd9000000` are **byte-identical to `bootloader.bin` at offset `0x200`**. The
ROM had already loaded BL2 from eMMC into SRAM, so reading it back validates the serial dump and the
USB protocol against each other in one shot.

So the earlier conclusion needs its scope narrowed rather than reversing: the box does not offer ROM
mode _by itself_, and no button press produces it — but one command from the vendor U-Boot does,
with no hardware modification. `pyamlboot` is usable, and the BL2 it needs for this board's LPDDR3
is already in hand at `bootloader.bin` offset `0x200`.

❓ Whether the flag survives a power cycle is untested.

### ROM mode does not get you a backup

The ROM protocol reads and writes memory and runs code. It has no notion of eMMC, so being in ROM
USB Boot mode is not by itself a route to an image. Something has to run _on_ the box that can both
reach eMMC and ship bytes to the host, and the candidates all fall down:

| Candidate                        | Why not                                                      |
| -------------------------------- | ------------------------------------------------------------ |
| vendor U-Boot over USB           | no `ums`, no `fastboot`, no `tftpput` — nothing to ship with |
| vendor U-Boot over serial        | 15.76 GB at 115200 is about 17 days                          |
| `update mread`                   | closed Amlogic binary, x86-64 Linux only                     |
| Libre Computer's prebuilt U-Boot | `AMLC` container, AES-CBC encrypted, built for their boards  |

The loader stages are split out under `stock/h96max-m20/loader-stages/` at the offsets BL1 and BL2
print — `bl2.bin` is 49152 bytes, the same size as the `u-boot.bin.usb.bl2` those pyamlboot board
directories ship, and it is the one piece that knows this board's LPDDR3. Pairing it with someone
else's encrypted TPL is speculative and was not attempted.

**So the eMMC backup goes through the SD card**, which is what item 1 of the port needs anyway: boot
a kernel via `aml_autoscript`, and the eMMC becomes a plain block device that `dd` can read to a USB
stick or across Ethernet.

### The eMMC BL2 is not a USB loader

First attempt at the maskrom-shaped flow: push the board's own `bl2.bin` through `boot.py`, let it
bring up LPDDR3, then hand it the board's own `bl33-uboot.bin` and drive `amlmmc` through
`tplCommand`, reading each chunk back with `readLargeMemory`. Every API for that exists.

It does not work with a carved BL2. `boot.py` wrote our `bl2.bin` to `0xd9000000` and ran it; from
that moment the ROM stopped answering `identify()` — `USBTimeoutError` — while the device stayed
enumerated, and serial printed nothing at all. eMMC was never touched; only SRAM and DRAM were
written, so a power cycle is the whole recovery.

The cause is the same distinction Rockchip has. The maskrom loader there is a **built** artifact —
DDR blob plus `usbplug`, packed by `rkdeveloptool pack` — not the idbloader lying on disk. Amlogic
splits the same way: `u-boot.bin.usb.bl2` is a BL2 built to _request the next stage over USB_
through the AMLC handshake, whereas the BL2 in the `bootloader` partition reads BL30/BL31/BL33 from
fixed eMMC offsets. Carving the second and using it as the first gets a BL2 that runs and then goes
looking at eMMC.

Getting three files out of one partition was still worth it: `bl2.bin` is the only artefact that
knows this board's LPDDR3, and it stays the reference for whatever loader eventually gets built.

Next, and cheaper: p212's own `u-boot.bin.usb.bl2` is a real USB-boot BL2 for this SoC family. ❓
whether its DDR init copes with this board's LPDDR3 rather than p212's own.

### The DDR blob is out

`gxlimg` builds on macOS with two portability fixes, both in `patches/gxlimg/`: macOS has no
`<endian.h>`, and `PATH_MAX` lives in `<sys/syslimits.h>`. The endian shim needs all six of
`htole`/`letoh` at 16, 32 and 64 bits even though grep finds only the 32-bit pair — `amlcblk.c`
builds the others by token pasting `le ## sz ## toh`.

`-t fip -e` on `bootloader.bin` first produced a BL2 that would not unsign, `Invalid BL2 header`.
The dump is an eMMC **partition**, and the FIP inside it starts at `0x200`; feeding the raw dump put
every extraction 512 bytes out of phase. Skipping `0x200` extracted all five stages at sizes
matching the carved ones exactly — 30208, 9728, 103936, 394752 — so the two methods agree, and
`gxlimg -t bl2 -u` then unsigned BL2 without complaint.

The ACS block inside that unsigned BL2 parses with all four magics intact:

| Region               | Address  | Length | Version |
| -------------------- | -------- | ------ | ------- |
| `ddrs_` DDR settings | `0x9700` | 388    | 3       |
| `ddrt_` DDR timing   | `0x9888` | 240    | 1       |
| `pll__` PLL          | `0x9978` | 16     | 2       |
| `acs__` struct       | `0x9988` | 64     | 1       |

`chip_type` is `0x24`. Rewritten into a standalone 804-byte container in `acs.bin`, laid out like
the ones `amlogic-boot-fip` ships, and it re-parses clean.

**It will not drop into a stock generic BL2.** lepotato's ACS is 384/336/64 against this board's
388/240/16, and `acs_tool.py`'s `check_acs` rejects a mismatch on anything but the three addresses.
This vendor BL2 comes from a later Amlogic SDK than any board in that repo. The addr fields sit at
offsets 24, 40 and 56 of the 64-byte struct, which is worth writing down because the field widths in
`acs_v1` are advance distances, not read widths.

### FORCE_USB_BOOT is volatile, and the cable decides the boot path

A power cycle clears it. After `set_usb_boot 2` and a reset the box is in ROM USB Boot mode, but cut
the power and it comes back a normal box. So the flag is safe to set — there is no state to get
stuck in, and `set_usb_boot 1` is only needed to undo it within the same power session.

With the USB-C cable attached, the box never reaches a U-Boot prompt. `preboot` runs
`try_auto_burn=update 700 750` **before** `Hit any key to stop autoboot`, and when a host is
actually on the other end that handshake succeeds, so U-Boot enters its burning gadget and stays
there. Serial then prints nothing but a repeating `ID[16]` and accepts no commands; Ctrl-C does not
break it.

| Want               | Cable                                                    |
| ------------------ | -------------------------------------------------------- |
| a U-Boot prompt    | unplugged                                                |
| the burning gadget | plugged                                                  |
| ROM mode           | `set_usb_boot 2` at the prompt, then plug in and `reset` |

So the order matters: get the prompt with the cable out, arm the flag, plug in, and only then reset.

### The re-signed BL2 is accepted; the run-parameter blobs are not

Repacking works. `gxlimg` round-trips this board's BL2 losslessly — unsign, re-sign, unsign again
gives back the same bytes — and a FIP rebuilt from the extracted stages re-extracts with BL31 and
BL33 byte-identical. LC's `aml-s905x-cc` BL33 decrypts to a mainline U-Boot that has `ums`, where
`p212`'s has `fastboot` instead, so a hybrid of this board's BL2/BL30/BL301/BL31 with that BL33 is
the shape worth booting.

Pushed into ROM mode it gets much further than the carved BL2 did:

```
ROM: 2.4 Stage: 0.0
Writing u-boot.bin.usb.bl2 at 0xd9000000... [DONE]
Writing usbbl2runpara_ddrinit.bin at 0xd900c000... [DONE]
Running at 0xd9000000... [DONE]
ROM: 2.4 Stage: 0.0              <- still answering after BL2 ran
Writing u-boot.bin.usb.tpl at 0x200c000... <- times out
```

The carved BL2 killed the link the moment it ran. The re-signed one runs and leaves the ROM
responsive, so the signing and the ACS inside it are right.

**`usbbl2runpara_ddrinit.bin` is the wall.** It is not generic data — it carries an entry offset
into BL2:

| Blob        | Magic      | Ver | Entry        |
| ----------- | ---------- | --- | ------------ |
| `ddrinit`   | `abcd1234` | 2   | `0x0000dfc0` |
| `runfipimg` | `abcd1234` | 2   | `0x0000e1c0` |

Those offsets belong to the reference BL2 that ships with pyamlboot. This board's BL2 is a later
build, so the call lands somewhere harmless instead of on DDR init — nothing prints on serial, where
a real init prints `LPDDR3 chl: Rank0+1 @ 600MHz` and a `bist_test ... PASS`. DDR stays down, and
the TPL write to `0x200c000` is a write to absent memory.

`runfipimg` also ends in what looks like a 12-byte hash, so the parameters may not be freely
craftable even once the right offsets are known.

Two ways forward, neither cheap: locate the DDR-init entry in this board's unsigned BL2 and craft
matching parameters, or inject this board's ACS into a BL2 whose offsets already match the stock
parameters — which is the 388/240/16 against 384/336/64 layout mismatch again.

### Both loader routes are blocked on the same seam, from opposite sides

The generic run-parameter blobs work because they match the BL2 shipped alongside them. Unsigning
`superna9999/aml-usb-load-uboot`'s `u-boot.bin.usb.bl2` — the one `run-uboot.sh` drives with those
exact blobs — shows why swapping either half fails:

| BL2                     | `ddr`    | `ddrt`   | `pll`   |
| ----------------------- | -------- | -------- | ------- |
| reference, params match | 384 / v2 | 336 / v1 | 64 / v1 |
| **this board**          | 388 / v3 | 240 / v1 | 16 / v2 |

So the DDR parameter block is a **different format version**, v3 against v2, not merely a different
length. Injecting this board's ACS into the reference BL2 would hand v3 data to code that parses v2.

That closes both directions:

| Combination                       | Blocked by                                                  |
| --------------------------------- | ----------------------------------------------------------- |
| reference BL2 + this board's ACS  | ACS format v3 vs v2                                         |
| this board's BL2 + stock params   | params hardcode entry `0xdfc0` into the reference BL2       |
| this board's BL2 + crafted params | needs its DDR-init entry offset; `runfipimg` ends in a hash |

`bulkcmd` in burning mode is the other open seam. `AM_REQ_BULKCMD` (0x34) accepts the command —
`ctrl_transfer` reported 11 bytes written for `echo hello\0` — but nothing comes back on the bulk IN
endpoint (0x81, 512-byte packets), nor from `AM_REQ_TPL_STAT`, and the gadget stops answering
afterwards, so the next command times out too. Amlogic's own docs say the handler replies `success`
or `failed:`, so the framing exists; neither `PROTOCOL.md` in pyamlboot nor the one in
`aml-usb-load-uboot` documents it. pyamlboot implements 0x30 and 0x31 and then skips 0x32, 0x33 and
0x34 entirely.

### bulkcmd runs arbitrary U-Boot commands, and the reply needs `wIndex == 2`

Amlogic's gadget source settles both questions. `optimus_transform.c`, the bulkcmd dispatcher, ends
with a fallthrough:

```c
else {
        int flag = 0;
        ret = run_command(cmd, flag);
}
if (ret) memcpy(buff, "failed:", strlen("failed:"));
else     memcpy(buff, "success", strlen("success"));
```

So anything it does not recognise as a burning command is handed to `run_command` — `set_usb_boot 2`
and `amlmmc read` included. Burning mode is reachable with the button and the cable alone, so none
of this needs serial.

`usb_pcd.c` explains why the first attempt got nothing back:

```c
case AM_REQ_BULKCMD:
        _pcd->bulk_len = w_value;   // block length
        _pcd->bulk_num = w_index;   // number of blocks
        _pcd->length   = w_length;
        if (2 == w_index) usb_set_reply_cmd_id(AM_REQ_BULKCMD);
```

The reply is armed **only when `wIndex` is 2**. The first attempt sent `wValue=0, wIndex=0`, so the
command was accepted — `ctrl_transfer` reported 11 bytes written — and no reply was ever queued.

The `update` binary's own strings show the transfer commands are themselves bulkcmds:
`upload %s %s %s 0x%lX` for `mread`, `download %s %s %s 0x%lX` for `mwrite`, with
`AM_REQ_UPLOAD`/`AM_REQ_DOWNLOAD` moving the payload afterwards.

### The stock environment boots from a USB stick, not just SD

`update` tries SD and then USB, and the USB branch is as capable as the SD one:

```sh
recovery_from_udisk=if fatload usb 0 ${loadaddr} aml_autoscript; then autoscr ${loadaddr}; fi;if fatload usb 0 ${loadaddr} recovery.img; then …bootm ${loadaddr};fi;
```

`autoscr` on `aml_autoscript` is arbitrary U-Boot script execution, and `recovery.img` with an
optional `dtb.img` is an arbitrary kernel through `bootm`. Both are reached with the button alone.
The stick goes in the **USB-A** port; USB-C is the OTG gadget, and `usb start 0` has to succeed
first. SD is tried before USB.

This is the cheapest backup route on the board: boot a kernel with an initramfs off the stick and
`dd` the eMMC onto a second partition of the same stick. No loader to build, no DDR parameters, no
closed tool, no x86 host.

### Commands over USB work; the data transfer does not

`src/amlcmd/README.md` carries the protocol. The two findings that mattered, both after hours of
wrong theories:

**Identify within 750 ms of the box appearing.** `try_auto_burn=update 700 750` is 700 ms to connect
and 750 ms to identify. `usb_pcd.c` arms a timer on SET_CONFIGURATION and abandons burning mode when
it expires; the identify handler sets `_auto_burn_time_out_base = 0` and disables the check for
good. That is how the vendor tool holds the link. Every "flaky link" symptom before this was the box
resuming its Android boot underneath the commands — visible on the serial console as kernel messages
while USB commands were still being sent.

**`buf[0x42] = 1`.** A command is `AM_REQ_TPL_CMD` with the text at offset 0 of a 64-byte data stage
and a 4-byte trailer supplying `wValue`/`wIndex`. The gadget runs the command only when
`w_index == 1`; with it zero the transfer succeeds and nothing happens, returning 64 zero bytes. The
vendor sets the same byte — `movb $0x1, -0x5e(%rbp)`.

The reply is a 64-byte control IN on `AM_REQ_TPL_STAT`, and it carries detail past the status word:
`optimus_transform.c` uses `memcpy` not `strcpy` so handlers can write at `buff + 7`. Truncating at
the first NUL discards the reason a command failed.

Measured after that: `printenv upgrade_step` → `success`, repeatedly, from independent invocations.
`disk_initial 0` → `failed:` but it is still a prerequisite; `upload store boot normal 0x1000` is
rejected without it and answers `success` after. The upload header then returns magic `0xefe8` and
length 4096, correctly.

**The bulk read returns 0 of 4096 and wedges the gadget.** `AM_REQ_UPLOAD` only fills `_resultInfo`;
`start_bulk_transfer()` is called from `AM_REQ_RD_LARGE_MEM`, which takes its source address from
the data stage. `amlcmd` passes 0 there. The real value is `OPTIMUS_DOWNLOAD_TRANSFER_BUF_ADDR` in
`khadas/u-boot`, and looking it up is the next step.

A wedged gadget has no serial console and answers no USB, so each failed transfer costs a power
cycle. Not every error reaches USB either: `disk_initial`'s diagnostics go to the UART, so logging
serial while driving over USB is how a bare `failed:` gets explained.

### The eMMC reads over OTG: `RD_LARGE_MEM` was never in the upload path

`OPTIMUS_DOWNLOAD_TRANSFER_BUF_ADDR` resolves to `0x07700000` — `DDR_MEM_ADDR_START` (`0x073<<20`)
plus the 2 MiB sparse-backup buffer. Looking it up settled the question by making it irrelevant:
`usb_pcd.c` starts the bulk IN from `do_vendor_in_complete`, the handler that runs once the 16-byte
`AM_REQ_UPLOAD` control IN has completed. Nothing else has to ask for the data. The extra
`AM_REQ_RD_LARGE_MEM` was a second `start_bulk_transfer` against a buffer address of 0, and that was
the wedge.

The second half was on the host. **The interface has to be claimed before the first bulk read.**
pyusb claims lazily, and doing that with a transfer already armed returns `EIO` and strands the
chunk in the gadget — a later read pulled the same 4096 bytes back out intact, which is what
identified it.

With both fixed, 4096 bytes of an `mw.l 0x20000000 11223344 400` pattern came back byte-exact.

### Raw sectors, and what the two paths agree on

`amlmmc list` prints `SDIO Port B: 0` and `SDIO Port C: 1`, so **the eMMC is `amlmmc` dev 1**. That
gives a raw route with no partition table in the way: `amlmmc read 1 <addr> <blk> <cnt>` stages
sectors in DRAM, `upload mem <addr> normal <size>` ships them.

Both routes were checked against each other at the `boot` partition, `0x55c00000` in
`partition-map.txt`:

| Route                                | First 16 bytes                    |
| ------------------------------------ | --------------------------------- |
| `upload store boot normal 0x1000`    | `414e44524f494421` … — `ANDROID!` |
| `amlmmc read 1 … 0x2ae000 8` + `mem` | identical                         |

So the offsets in that map are absolute eMMC offsets, and the `store` layer and a raw sector read
return the same bytes. **8.5 MiB/s measured** over a 8 MiB window, which puts the whole 15.76 GB at
about half an hour. A 512 KiB window reports 0.79 MiB/s — that is fixed cost, not throughput.

**Sectors 73760–74271 refuse to read**: `Emmckey: Access range is illegal!` from
`emmckey_is_access_range_legal`, the 256 KiB key window inside `reserved`. `store disprotect key`
lifts it for the session and the read then succeeds — 995 non-zero bytes in the surrounding MiB,
matching a key store with only `mac` and `usid` provisioned.

**The first command after `connect` arrives with its first four bytes eaten.** `mw.l 0x20000000 …`
reached the box as ` 0x20000000 …`; the identical retry arrived whole. That is the
`failed:`-then-`success` anomaly, and it means the first command must be a throwaway.

### The write direction wedges the gadget twice, both times on framing

Neither failure reached eMMC; both cost a power cycle, and neither `clear_halt` nor a USB-level
`reset` clears a wedged gadget — it stays enumerated and answers nothing, with no serial console.

| Attempt                         | Error               | Cause                                             |
| ------------------------------- | ------------------- | ------------------------------------------------- |
| ack read of 64 bytes            | `Errno 84 Overflow` | libusb will not ask a 512-byte endpoint for less  |
| one 64 KiB `ep.write` per chunk | `Errno 32 Pipe`     | the gadget re-arms every `DWC_BLK_MAX_LEN` = 4096 |

`download mem … normal 0x30000` itself is accepted both times — serial prints
`totalSlotNum = 0, nextWriteBackSlot 3` — so the setup command and its 32-byte parameter block are
right and only the bulk framing was wrong. pyamlboot writes one armed block per `ep.write` call for
exactly this reason.

### Both directions work, and the C client is what ships

The write path was three framing bugs deep, each costing a power cycle, and none of them reached
eMMC:

| Symptom             | Cause                                                 |
| ------------------- | ----------------------------------------------------- |
| `Errno 84 Overflow` | the ack was read as 64 bytes from a 512-byte endpoint |
| `Errno 32 Pipe`     | a 64 KiB write to a gadget that re-arms every 4 KiB   |
| `Errno 32 Pipe`     | a speculative drain: a timed-out read halts the pipe  |

The third was self-inflicted — a drain added defensively before every transfer. As an explicit
`amlcmd drain` after a failure it is the right tool, and it recovers a stranded chunk without a
power cycle; run before a healthy transfer it halts the endpoint.

A C client using libusb directly failed where the Python one worked, twice, on the first bulk read.
**The cause was the teardown, not the protocol**: the C tool exited without
`libusb_release_interface`, leaving the pipe halted for the next invocation, where pyusb releases on
exit. With an `atexit` teardown it works with zero endpoint retries, and the `read_bulk` retry added
for a suspected arm-race never fires — so the race was never real.

Measured on the same 64 MiB of eMMC, the two clients are within 2% and produce byte-identical
images:

| Client | 64 MiB | Rate       | Host CPU |
| ------ | ------ | ---------- | -------- |
| C      | 6.04 s | 10.6 MiB/s | 2%       |
| Python | 6.17 s | 10.4 MiB/s | 5%       |

That settles where the time goes: the host is idle, and the cost is the gadget's one control round
trip per 64 KiB slot plus an endpoint re-arm every 4 KiB from U-Boot's polling loop. Both are
compile-time constants in the vendor bootloader, so no client reaches them. The C one ships because
it needs no venv and recovers from its own errors, not because it is faster.

**The first full eMMC image came off the box this way** — 15028 MiB at a steady 10.8 MiB/s,
`backup/h96max-m20/emmc-full.img`, no SD card and no booted kernel. The `store disprotect key` in
front of it is what lets a whole-device pass cross the key window at sectors 73760–74271.

Entering burning mode from the U-Boot prompt with `update` is the most repeatable of the three
routes: a newline during `Hit any key to stop autoboot` gets the prompt, and the gadget then waits
indefinitely instead of racing the 750 ms window.

### What the button reaches, restated with the evidence

The recovery button cannot produce ROM USB Boot mode on this box, and `identify()` is what settles
it rather than inference: button-held enumeration answers `ROM 0.7 / Stage 0.16` and every memory
read fails, where the mask ROM answers `ROM 2.4 / Stage 0.0` and returns data. Both present
`1b8e:c003`, which is why the first reading was wrong.

The button is sampled by U-Boot itself — the boot log prints `detect sadckey ....` immediately
before `Enter USB burn` — so BL1 and BL2 have already loaded from eMMC by the time anything reads
it. `upgrade_sadckey` runs `update`, and that is U-Boot's own gadget by construction.

`amlmmc size wholeDev` returns 30777344 sectors, the same count Android reports, so the capacity the
backup walks is the real device and not a partition view.

### Both directions verified, and `pyamlboot` folded in

`restore` writes across staging windows correctly: 64 MiB of `cache` read, written back and re-read
byte-identical. The full device came off at 15758000128 bytes — exactly 30777344 × 512, the sector
count `amlmmc size wholeDev` reports — and spot-checks confirm it is the real device: `ANDROID!` at
the `boot` and `recovery` offsets, an ext4 superblock at each of `vendor`, `system`, `odm` and
`product`, and 792 non-zero bytes inside the key window that only reads at all with the guard
lifted.

**The burning gadget reaches the mask ROM without serial.** `set_usb_boot` is an ordinary U-Boot
command, so it arrives through the same fallthrough as everything else:

```sh
amlcmd set_usb_boot 2
amlcmd reset                 # BL2 prints `Skip usb!`, and identify turns into ROM 2.4 Stage 0.0
```

So `pyamlboot` had nothing left that `amlcmd` could not do. The mask ROM answers the **same vendor
request space** as the burning gadget — identify is `0x20` in both — with a different handler set,
so folding it in was `READ_MEM`, `WRITE_MEM` and `RUN_IN_ADDR`, about eighty lines. `rom read` of
`0xd9000000` now returns 4096 bytes matching `bootloader.bin` at `0x200` exactly, where the earlier
pyamlboot check only compared 16. The venv, pyusb and pyamlboot are gone; `build-amltools.sh`
compiles one C file.

**eMMC is unreachable from the mask ROM, and asking wedges it.** `printenv`, `amlmmc list` and a raw
sector read were each tried in ROM mode: all three returned nothing, and afterwards identify timed
out, costing a power cycle. The ROM has no command interpreter for `AM_REQ_TPL_CMD` to reach.
`amlcmd` now refuses everything but `rom` once identify says ROM 2.4, the mirror of the check that
already refused `rom` on the burning gadget.

### The mask ROM serves SRAM only, so the loader route is still shut

BL2 does bring DDR up before handing back. On the reset after `set_usb_boot 2` serial prints
`lpddr3 remap(ID:11-RC2)`, `lpddr3-2 board` and `CPU clk: 1200MHz`, and only then `Skip usb!`. That
looked like it might retire the "needs a BL2 for this DRAM" blocker outright.

It does not. In ROM mode `rom write 0x20000000` fails, and afterwards the box leaves the bus
entirely — the ROM powers its PHY off. `rom read 0xd9000000` works in the same session, so the
window is SRAM and not DRAM. That matches the earlier failure where pushing a TPL to `0x200c000`
timed out: whatever BL2 did to the memory controller, the ROM's own memory window does not follow
it.

**There is no route from ROM mode back to U-Boot without cutting power.** `set_usb_boot` is
`SET_USB_BOOT_FUNC`, SMC `0x82000043` into BL31, so the flag lives in secure world and is not a
register the ROM can poke. `rom run` on a watchdog stub would be a warm reset, and only a power
cycle is known to clear the flag, so the likely outcome is a loop back into ROM mode.

Practical consequence: enter ROM mode only to unbrick. The burning gadget does everything else, and
it can be left and re-entered with `reboot update` from Android or `update` at the U-Boot prompt.

### Command sweep, and the numbers for the write direction

`amlmmc part 1` prints the partition table in sectors, and it agrees with every offset derived
independently from `partition-map.txt`: `bootloader` at 0, `reserved` at 73728 with the key window
73760–74271 inside it, `cache` at 221184, `boot` at 2809856 — the sector where `ANDROID!` verified.

| Command                | Result                                                       |
| ---------------------- | ------------------------------------------------------------ |
| `version`              | ✅                                                           |
| `bootloader_is_old`    | ✅                                                           |
| `printenv bootcmd`     | ✅ `bootcmd=run storeboot`                                   |
| `amlmmc part 1`        | ✅ the whole table                                           |
| `store size boot`      | `failed:` — correct, `store` has no `size`, it printed usage |
| `get_chipid`           | `Unknown command` — not built into this box's U-Boot         |
| `md.b 0xd9000000 0x10` | **resets the box** — `Resetting CPU ...` on serial           |

`md` is claimed by the gadget before `run_command` sees it, and it takes the box down. It reboots
cleanly into Android rather than wedging, so it costs a re-entry and not a power cycle. `read mem`
is the way to read memory.

256 MiB of `cache` read, written back and re-read identical:

| Direction | 256 MiB | Rate       |
| --------- | ------- | ---------- |
| read      | 20.6 s  | 12.4 MiB/s |
| write     | 27.4 s  | 9.3 MiB/s  |

### The vendor firmware came out of the image, not the box

With a full eMMC image on disk, `vendor` is an ext4 filesystem at sector 3059712 and the patched
`e2tools` reads it directly. `stock/h96max-m20/firmware/` now holds what the MT7668 driver needs —
`WIFI_RAM_CODE_MT7668.bin`, `WIFI_RAM_CODE2_SDIO_MT7668.bin`, both patch headers,
`EEPROM_MT7668.bin`, `TxPwrLimit_MT76x8.dat` and `bt.cfg` — so Wi-Fi and Bluetooth bring-up no
longer needs the box attached.

Nothing else on the box is worth preserving: seventeen of the nineteen unifykey slots are empty,
every DRM one included, and only `mac` and `usid` hold anything.

### The raw image carries the bootloader, and that cross-checks the whole backup

The first 4 MiB of `emmc-full.img` is byte-identical to `stock/h96max-m20/bootloader.bin`, which was
pulled from `/dev/block/bootloader` over the serial console a day earlier by a different route
entirely. Sector 0 is zero padding and BL2 starts at `0x200`, so a raw sector pass over the user
area does carry the bootloader — `boot0`/`boot1` hold copies, not the only copy, and nothing is
missing from the image.

That also answers what the media verbs are for once `backup`/`restore` exist. `read store` is
redundant — a sector range reaches the same bytes. `read mem` is not: `md` resets the box, so it is
the only way to read memory over USB without rebooting. `write mem` is the only bulk memory write,
`mw` being four bytes per command round trip. They were called `dump`/`push` until it was pointed
out that the pair does not even match; `read`/`write` lines up with `rom read`/`rom write`.

### USB host and the burning gadget cannot both run

`usb start` issued through `amlcmd` takes the box down:

```
scanning bus 0 for devices... 2 USB Device(s) found
scanning usb for storage devices... WARN halted endpoint, queueing URB anyway.
Unexpected XHCI event TRB, skipping...
"Synchronous Abort" handler, esr 0x96000210
Resetting CPU ...
```

The same command at the plain U-Boot prompt, with no gadget running, reports
`1 Storage Device(s) found` and works. So the host-side scan trips over the OTG port that is in
device mode, and anything involving USB storage has to be driven from the prompt over serial, not
over `amlcmd`.

### The env variable was the wrong lever, and the restore path proved itself

`identifyWaitTime` is the variable the gadget checks before arming its identify timeout, and it is
absent from the factory environment — which looked like the reason `reboot update` parks forever
while the button path times out. Setting it to 2000 and `saveenv`-ing it changed nothing:
`reboot update` still stopped at `set CFG`.

The check is guarded by the work mode:

```c
if (OPTIMUS_WORK_MODE_USB_UPDATE == optimus_work_mode_get()) {
        if (getenv("identifyWaitTime")) _auto_burn_time_out_base = get_timer(0);
}
```

`update` sets `OPTIMUS_WORK_MODE_USB_PRODUCE`, so the env var is inert on that path. What separates
the two callers is the argument count — `try_auto_burn=update 700 750` reaches the mode that times
out, `usb_burning=update 1000` does not. The button prints `waitIdentifyTime(751) > timeout(750)`
and falls through; `reboot update` never does.

`upgrade_sadckey` samples the button twice, a second apart, and only then runs `update`: a tap
prints `detect sadckey ....` and nothing else, which is why early button attempts looked like they
did nothing.

**Undoing it exercised restore on something that matters.** The `env` partition was written back
from backup at sector `0x26A000`, read again, and compared: byte-identical. The same 8 MiB extracted
from `emmc-full.img` with `dd skip=2531328 count=16384` matches both, so the whole-device image is
genuinely restorable per partition and a separate env dump was redundant.

## 2026-09-20 - amlcmd stops being one box's tool

The three constants a port had to edit - the eMMC device, the staging address, the window - are read
from the environment now, with this box's measured values as the defaults, and `AML_VID`/`AML_PID`
and `AML_MODE` join them. Another family needs no rebuild.

Two assumptions in the code were this family's rather than the protocol's. `is_mask_rom` keyed on
ROM major 2, which is GXL's; it keys on Stage 0.0 instead, which is what a ROM with nothing staged
behind it answers whatever the family. `store disprotect key` was fatal on failure, so a box with no
key window could not back up at all; it warns and carries on.

Both defaults still describe this box, and there is no second family here to try the rest on.

### What the box can be asked, and what it cannot

`amlcmd probe` was added on the back of two things that already cross USB: a command's verdict, and
memory the box itself wrote. From those it names the gadget and its ids, sizes the boot device, and
finds the eMMC as the only device that can read the last sector of that size - an absent or smaller
one fails there. `backup` and `restore` run the same discovery when `AML_MMC_DEV` is unset, and a
restore refuses to guess.

The staging address stays configured. A write is the only way to test one, and a write to an address
the box has no DRAM for is the write that wedges it, so discovery can reject the configured address
by reading a pattern back but cannot search for a better one.

`amlmmc size wholeDev` no longer aborts a run when it fails - a ranged backup never needed it.

None of this has been run on the box: it is written against commands this box has answered, and the
sequence itself is untested.

### Correction: pyamlboot implements the whole request set

An entry above says pyamlboot implements 0x30 and 0x31 and then skips 0x32, 0x33 and 0x34. Read
against its master today that is wrong: it has `writeMedia` (0x32), `readMedia` (0x33), `bulkCmd`
(0x34), and beyond them `getBootAMLC` (0x50), `writeAMLCData` (0x60), large memory (0x11, 0x12), the
register operations (0x03, 0x04, 0x06, 0x07) and the ROM password (0x35). It also carries ADNL, the
newer protocol that puts commands on bulk read and write rather than vendor requests.

What it does not carry is the workflow `amlcmd` exists for: the staged eMMC loop, the key guard, and
the reply detail past the status word. The honest claim is that this repo needs no Python stack, not
that pyamlboot lacks the protocol.

## 2026-09-26 — a first boot without serial, on paper

- Correction: the first stick boot of 2026-09-17 was driven over serial, not by the button, as every
  one since has been. `amlcmd` is the route meant to replace it.
- The published `amlcmd setenv bootcmd '…'` recipe could not work: the line is about 110 bytes
  against a 64-byte command, and `passthrough()` joins arguments with spaces, so the shell's quotes
  are gone and U-Boot splits the value at every `;`.
- Rewritten to fit, with no `;` and no quotes: `setenv usb_on usb start 0`, then
  `setenv bootcmd run usb_on recovery_from_udisk storeboot` (55 bytes). `setenv` joins its extra
  arguments and `run` takes several names, so the stock `recovery_from_udisk` runs the stick's
  `aml_autoscript`, which does the full rewrite. Not yet run.
