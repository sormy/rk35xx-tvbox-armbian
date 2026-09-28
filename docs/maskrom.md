# Maskrom and Loader — entry, backup, restore

The USB service modes these boxes expose, and the traps. Matters most on a box with **no card
slot**, where this is the only way in or back.

```text
BootROM (silicon) -> idbloader @ 64 (DDR init + SPL) -> U-Boot @ 16384 -> kernel
```

`Maskrom` is the BootROM itself, so it survives an erased chip — that is why it is the rescue, and
why `db` comes first: DRAM is not up until a DDR-init loader is uploaded.

## Peripherals — order these first

Only the OTG port answers, and charge-only cables enumerate nothing. The spine is a **USB-A
male-to-male** cable; add a **C-male→A-female adapter at each end that is USB-C**.

| Box port | Host port | Chain               |
| -------- | --------- | ------------------- |
| USB-A    | USB-A     | cable alone         |
| USB-A    | USB-C     | + adapter at host   |
| USB-C    | USB-A     | + adapter at box    |
| USB-C    | USB-C     | + adapter both ends |

❌ A **classical USB-C→USB-A cable with the USB-C end in the host does not work for OTG** — no
enumeration.

- [USB-A male-to-male cable](https://www.amazon.com/dp/B0CLB4Y5XD) (~$4)
- [USB-C male → USB-A female adapter](https://www.amazon.com/dp/B0DSK82JK8) (~$8 for 4)
- [3.3 V USB-TTL, FT232 or CH340](https://www.amazon.com/dp/B0CX55K4RG) (~$14) — must do **1.5
  Mbaud**. **Not a CP2102**: it cannot, and prints plausible garbage
- [Test-hook probe pins](https://www.amazon.com/dp/B09TPBS7YF) (~$15.0) - for any serial points that
  are tiny

**Order the serial adapter even if the toothpick button works today** — the button wiring lives in
U-Boot and dies with it, `ctrl+b` does not. Pinout and baud are per board, in its `board.md`.

✅ **The A-to-A cable alone powers every board here** — no PSU, and none has needed one, through
sustained multi-GB transfers in both directions.

## Entering

> ⚠️ **Exactly one 5 V source.** These boxes do not decouple the rail, so a PSU and the host's VBUS
> backfeed into each other and can damage either end. The OTG cable powers the box — so the PSU
> comes out first, and stays out.

**Try the button first**, held _before_ power reaches the box:

```sh
tools/rktools/rkdeveloptool ld     # Maskrom, Loader, or nothing
tools/rktools/rkdeveloptool rd 3   # only if it said Loader
tools/rktools/rkdeveloptool ld     # must now say Maskrom
```

> ⚠️ **Never work from the factory `Loader`** — the vendor's rockusb is broken in several ways, the
> worst being a silent 32 MB read cap that returns `0xCC` while still printing `100%`.

**Every route known here.** A route is served by one stage and dies with it — which is why `ctrl+b`
outlives the button, and why the lower the stage, the more it survives:

| Stage                | Route                                 | Needs                 |
| -------------------- | ------------------------------------- | --------------------- |
| BootROM              | idbloader unreadable — just plug in   | cable                 |
| BootROM              | short CLK or D0                       | cable + probe + hours |
| idbloader @ 64 (SPL) | `ctrl+b` in a ~100 ms window          | cable + serial        |
| U-Boot @ 16384       | the button (if the DT is correct)     | cable                 |
| U-Boot @ 16384       | any key in the 2 s delay, then `mw.l` | cable + serial        |
| booted OS            | `reboot maskrom`                      | any access to the OS  |

The BootROM rescues you only when it never handed off — so **erasing sector 64 is recoverable,
writing a wrong DDR blob there is not.** `ctrl+b` needs DRAM up, so it is only ever as good as the
DDR init beside it in the same block.

✅ **A vanilla Armbian install keeps `ctrl+b`** — its ROCK 2F idbloader carries the same
`ctrl+b: Bootrom download!` and `back_to_bootrom()` as every factory loader here, so a box bricked
by stock `armbian-install` is still reachable over serial. 🟡 Unknown whether that image's older
`ddr-v1.09` brings up every board's DRAM.

**No `rd` subcode works before `db`.** They are answered by `usbplug` — the loader's CODE472 entry,
which `db` uploads and runs — not by the BootROM. Before `db` every one fails with
`Reset Device failed!` (exit 1) and changes nothing; after it they all succeed, and on a bus-powered
box they are indistinguishable, since VBUS re-powers it immediately.

| Command | Subcode           | Before `db` | After `db`                        |
| ------- | ----------------- | ----------- | --------------------------------- |
| `rd`    | `NONE`            | ❌ fails    | reboots the box                   |
| `rd 1`  | `RESETMSC`        | ❌ fails    | reboots the box                   |
| `rd 2`  | `POWEROFF`        | ❌ fails    | powers off, VBUS restarts it      |
| `rd 3`  | `RESETMASKROM`    | ❌ fails    | clears usbplug, back to `Maskrom` |
| `rd 4`  | `DISCONNECTRESET` | ❌ fails    | reboots the box                   |

So none of them rescues a **wedged** session: they need a working `usbplug`, which is precisely what
is missing. A replug is still the only way out of that.

### 1. The recovery button

Hold it, then plug the cable in. Location differs per board: AV jack, pinhole, PCB. It is read by
U-Boot, so it dies with a FIT that has no ADC — see each `board.md`.

### 2. `ctrl+b` at the vendor SPL

The window is **~100 ms**, so the key must be streamed while the board powers up, never typed. On
macOS `tcsetattr` will not do 1.5 Mbaud; `IOSSIOSPEED` is required:

```sh
python3 - /dev/cu.usbserial-XXXX <<'EOF' &
import fcntl, os, struct, sys, termios, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0], a[1], a[3] = termios.IGNPAR, 0, 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B9600          # tcsetattr rejects 1500000; the ioctl below sets it
termios.tcsetattr(fd, termios.TCSANOW, a)
fcntl.ioctl(fd, 0x80085402, struct.pack("L", 1500000))
end = time.time() + 120
while time.time() < end:
    os.write(fd, b"\x02")           # ctrl+b
EOF
# now power-cycle the board; then:
./tools/rktools/rkdeveloptool ld     # Maskrom
```

Kill the loop once `ld` says `Maskrom`, or it holds the port.

### 3. The U-Boot console

Any key within `bootdelay=2` gets a prompt. Write the download flag and reset — the SPL reads it on
the way back up and hands to the BootROM, the same path `reboot maskrom` takes:

```text
=> mw.l 0xff370200 0xef08a53c   # BOOT_MODE_REG, BOOT_BROM_DOWNLOAD
=> reset
```

### 4. Shorting eMMC CLK or D0 to GND

❓ Never attempted here. For one case only: the idbloader loads but its SPL hangs. No board here has
test points — you must find the trace on a fine-pitch BGA fan-out, likely scrape solder mask, and
time the short against power-up. **Prove routes 1 and 2 while the box still boots** and you will not
need it.

### 5. From a booted OS

```sh
sudo reboot maskrom          # Maskrom in ~5 s; SSH is enough
```

Every board's tree declares the `mode-maskrom` this needs. It wants a working OS, so it is the first
route to go when a box is genuinely broken — `ctrl+b` still outranks it.

## Backup to image over USB

`db` uploads Rockchip's `usbplug`, which has no read cap.

```sh
./build-rktools.sh                                     # -> tools/rktools/
tools/rktools/rkdeveloptool db tools/rktools/rk3528_spl_loader-<board>.bin
tools/rktools/rkdeveloptool rfi                        # total sectors, e.g. 30777344
tools/rktools/rkdeveloptool rl 0 <sectors> emmc-stock.img
```

Try the single pass first — it completes on a healthy board. If it stalls, see **Traps**.

**One loader per board**: it carries that board's own DDR init, so they are not interchangeable.

Verify before trusting a dump — it must be `<sectors> × 512` bytes, and sector 64 must match the
board's own idbloader:

```sh
cmp <(dd if=emmc-stock.img bs=512 skip=64 count=4096 2>/dev/null) firmware/<board>/factory_idbloader.bin
```

## Write an image over USB

The only way onto a box with no card slot, and the way back on any box. **Back up first** — see
above. With the box in `Maskrom`:

```sh
tools/rktools/rkdeveloptool db tools/rktools/rk3528_spl_loader-<board>.bin
tools/rktools/rkdeveloptool wl 0 <image>
```

The factory window is blank unless `build-image.sh` was given `FACTORY_DUMP`. If it was not, put
7168-16383 back from your dump — **after** the image, since `wl 0` writes the whole chip:

```sh
dd if=emmc-stock.img of=window.bin bs=512 skip=7168 count=9216     # on the host
tools/rktools/rkdeveloptool wl 7168 window.bin
tools/rktools/rkdeveloptool rd
```

Skip it and the box loses its label MAC and serial, and nothing else. Once it boots, confirm with
`rk35xx-vendor-storage lan` — it must match the label.

## Traps

- **`db` fails** — almost always a wrongly packed loader; rebuild with `./build-rktools.sh`. The
  real error is in `log/` beside the binary, not on the console.
- **On macOS the first `db` raises an accessory-approval prompt** — until accepted the device
  vanishes from `ld`, looking exactly like a failed `db`.
- **`Creating Comm Object failed!`** — the interface is still claimed by a killed `rkdeveloptool`;
  replug. macOS needs no root, Linux may want a udev rule.
- **A second `db` always hangs** — usbplug is resident, so the BootROM is gone. After a _stalled_
  transfer `rd 3` hangs too and only a replug helps.
- **`ld` prints `Maskrom` either way** — to tell whether usbplug is loaded, do a small read
  (`rl 0 8`).

### A transfer stalls

#### Reading

**The pre-flight signal is the factory tree's own eMMC tuning** — read `sdhci` in
`stock/<board>/board.dts` before you start. A downclocked eMMC is the vendor saying the board is
marginal.

| Factory `sdhci` tuning | One-pass 15.7 GB read |
| ---------------------- | --------------------- |
| full clock, HS200      | ✅ completes          |
| halved clock, no HS200 | ❌ dies at ~12.4 GB   |

How far a stalling board gets depends on how recently it was worked — 12.58 GB from idle, then 0.59
GB minutes after that stall.

❓ **Cause unknown** — not the loader and not the media; every sector a read died on re-read cleanly
later.

**A falling rate warns, a steady one does not.** A stalling board usually slides first — 18 MB/s to
16 KB/s — but one held 25-27 MB/s flat for 500 s and then stopped dead.

A stall kills the session, not the disk, so chunk it and lose only the chunk in flight:

```sh
SECTORS=30777344                     # `rfi` reports it; check it against the label
STEP=4194304                         # 2 GiB — a stall costs at most this much; halve if needed
for ((s = 0; s < SECTORS; s += STEP)); do
  n=$((SECTORS - s < STEP ? SECTORS - s : STEP))
  tools/rktools/rkdeveloptool rl "$s" "$n" "$(printf 'chunk.%09d.img' "$s")" || break
done
cat chunk.*.img > emmc-stock.img     # %09d so the glob sorts numerically
wc -c < emmc-stock.img               # must equal SECTORS x 512
```

On `break`, replug and restart from the failed offset; chunks already written are kept. Budget
roughly one replug per 12 GB.

#### Writing

A full 15.76 GB `wl 0` completes in one pass on a full-clock board at 14-18 MB/s without degrading.
A board whose reads stall needs its writes chunked too. Unlike a read, **a broken run leaves the box
unbootable until the write finishes**, so resume from the failed offset rather than walking away.

```sh
IMG=emmc-stock.img
SECTORS=$(( $(wc -c < "$IMG") / 512 ))
STEP=4194304                         # 2 GiB — a stall costs at most this much; halve if needed
for ((s = 0; s < SECTORS; s += STEP)); do
  n=$((SECTORS - s < STEP ? SECTORS - s : STEP))
  dd if="$IMG" of=part.img bs=512 skip="$s" count="$n" status=none
  tools/rktools/rkdeveloptool wl "$s" part.img || break
done
rm -f part.img
```
