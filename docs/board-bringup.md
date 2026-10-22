# Bringing up a new board

Copy the closest existing board and change only what the evidence says to change. Adding a board is
data, not code.

| Step                   | Who   | Rough time |
| ---------------------- | ----- | ---------- |
| Serial                 | human | 20 min     |
| Evidence + backup      | both  | 40 min     |
| Device tree            | agent | 30 min     |
| Board data             | agent | 15 min     |
| Build + verify offline | agent | 5 min      |
| Validate               | both  | 1–2 h      |

## Serial first (human, blocking)

The only view of U-Boot, early boot, and any hang before networking. Nothing else starts until it
works.

1. Open the case — plastic pry tool; clips, not glue.
2. Find the 3–4 pin header, usually near the SD slot or the SoC.
3. **Find GND** with a meter: powered box, measure each pin against exposed metal (USB shell, SD
   cage, Ethernet jack). GND reads 0 V; of the rest 3V3 reads highest, TX/RX a few mV below.
4. Wire **GND, TX, RX only**, crossed. Never connect 3V3 — the box is self-powered and tying rails
   can backfeed.
5. `tio -b 1500000 -L --log-file boot.log /dev/…`, then power-cycle.

**Gate:** the vendor boot log scrolls.

- The adapter must be **3.3 V FT232 or CH340**. A CP2102 cannot do 1.5 Mbaud and prints plausible
  garbage.
- TX/RX is a coin flip. Swapping harms nothing, but unplug and replug the adapter between attempts.

**Record** in `docs/<board>/`: pad location, pinout with the square pad marked, board photo.

## Evidence, then backup (blocking)

The box's own firmware is the specification. Capture it before changing anything.

1. Boot stock Android and get a shell (serial, or `adb` over the network). If neither works the DTB
   and partitions can still be carved from the eMMC later, but `dmesg`/`getprop` are lost — try
   first.
2. Dump to `stock/<board>/`: `dmesg`, `cmdline`, `getprop`, `/proc/iomem`, `lsmod`, partition table,
   Wi-Fi/BT firmware from `/vendor`.
3. **Full eMMC image → `backup/<board>-stock.img.xz`**; verify byte count =
   `/sys/block/<dev>/size × 512`, then `xz -T0`. ~25 min at 100 Mb/s — start on the device tree
   while it runs.
4. Carve `factory_idbloader.bin` (sector 64, 4096 sectors) → `firmware/<board>/`.
5. Carve `board.dtb` out of the eMMC image — see below.

**Gate, no exceptions:** the eMMC dump exists off-box and its size is verified. It is the only route
back to Android once you migrate.

### The DTB must come from the dump, never from `/proc/device-tree`

`/sys/firmware/fdt` and `/proc/device-tree` give the tree **after U-Boot has edited it**, and the
edits are not cosmetic. On the R69 the bootloader adds two `/memreserve/` entries, `serial-number`,
the `memory` node, `chosen/bootargs`, initrd pointers, a `drm_logo` reservation and TVE overscan
margins, and **rewrites the SoC `compatible` from `rockchip,rk3518` to `rockchip,rk3528a`**. Take
that as the factory tree and you document properties the vendor never shipped.

On this family the base DTB sits inside the `boot` partition (Android boot image, header v2 — there
is no `resource` partition). Find it by its `d00dfeed` magic and read `totalsize` from the next four
bytes:

```sh
# boot partition start comes from the GPT; two identical copies exist, either will do
python3 - <<'EOF'
import lzma, struct
buf = lzma.open('backup/<board>-stock.img.xz')
buf.seek(51200*512); d = buf.read(64*1024*1024)
i = d.find(b'\xd0\x0d\xfe\xed')
open('stock/<board>/board.dtb','wb').write(d[i:i+struct.unpack('>I', d[i+4:i+8])[0]])
EOF
```

Keep a runtime blob too, as `board-runtime.dtb` — its diff against the pristine one is the only
record of what the bootloader does. Derive from the pristine one.

## Device tree

Derive `board.dtb` from the box's own factory Android DTB, never from a reference board's. Apply
only these grafts, each with a functional consumer:

| Graft                                               | Consumer                                                          |
| --------------------------------------------------- | ----------------------------------------------------------------- |
| IR `remote_support_psci` → `1`                      | remote wakes the box from off                                     |
| GPU → lima `clocks`/`clock-names`/`interrupt-names` | Armbian uses mainline lima                                        |
| LEDs → labels `power`/`standby`, `retain-state-*`   | the shared LED hooks                                              |
| `watchdog` → `okay`                                 | systemd `RuntimeWatchdogSec`                                      |
| board `compatible` prepend                          | only if a driver keys firmware lookup off it                      |
| SoC `compatible` append                             | only if userspace can't name the SoC without it — the codec check |
| `model` → the box's own name                        | identifies the board; the factory string names the reference EVB  |
| CEC → mainline's node, `hdmi-phandle` to HDMI TX    | `/dev/cec0`; the factory node may be a vendor binding             |
| DDC → `i2c-gpio` on its pins, HDMI `ddc-i2c-bus`    | DDC/CI, where the HDMI controller's own master reads EDID only    |

**The watchdog graft carries a hazard.** Once something opens `/dev/watchdog` it cannot be disarmed
short of a reset, and it keeps counting across a soft reboot. Check the board's watchdog clock
before trusting any timeout figure — `watchdog.md` has the arithmetic and the operational rule.

**Why the LED grafts look odd.** `retain-state-shutdown` / `retain-state-suspended` stop the LED
core clearing the LED at shutdown and applying `LED_CORE_SUSPENDRESUME`, which would fight the
`system-shutdown` / `system-sleep` hooks over which LED is lit. DT can express only half of it
anyway: it turns the blue LED **off** at poweroff, but nothing in DT turns the red one **on**
(`default-on` fires at probe, `panic-indicator` at panic). So the policy lives entirely in the hooks
and the tree just keeps the kernel's hands off.

**The DDC bus needs its pins muxed to GPIO.** The bootloader leaves them on the HDMI controller, and
GPIO lines without `gpio-ranges` never ask pinctrl to switch: give the `i2c-gpio` node a pinctrl
state with the SoC's GPIO function, or the EDID reads empty and the panel drops to a fallback mode.

**Leave everything else factory.** If nothing consumes it, don't graft it. Most
`status = "disabled"` nodes are unwired on that PCB (i2c, spi, spare uarts/pwms, audio codecs):
Rockchip's SoC dtsi disables everything and the board file enables what's wired. Only in-SoC blocks
needing no board routing are candidates.

- **The grafts live in `firmware/<board>/board.patch`**; `./build-board-dts.sh` produces
  `firmware/<board>/board.dts` + `.dtb` from it. Edit the patch, never `firmware/` — except where a
  board diverges on purpose, which belongs in its `dtb.md` with the condition that ends it.
- **To move a board onto a kernel's own reference design**, run
  `scripts/rebase-board-dts.py <board>` on the host, adding `--rev <commit>` to choose the kernel.
  It rewrites `board.dtb` as overrides on that dtsi in `build/rebase/<board>/native.dts`, and fails
  unless that compiles content-identical.
- **Verify the tree round-trips** before rebuilding:
  `diff <(dtc -I dtb -O dts board.dtb) <(dtc -I dtb -O dts <(dtc -@ -I dts -O dtb board.dts))`. If
  it doesn't, edit with `fdtput` instead.
- **Diff the result against the factory tree**; the only differences must be your grafts.
- **One change per test DTB**, serial attached. Two at once cost a day of not knowing which hung the
  boot.
- Record every change in `docs/<board>/dtb.md`, including tried and reverted ones.

## Board data

Copy the closest `firmware/<board>/` and edit: `board.conf` (`BOARD_FAMILY`, required,
`BOARD_HOSTNAME`, `BOARD_KERNEL`, `BOARD_DEPENDS`), `package.list`, `board-id`, `board-name` (the
login banner — carry the PCB silkscreen, since these boxes vary between production runs), plus the
DTB and idbloader. Create `docs/<board>/`, starting `worklog.md` on day one, and add the board to
the README's Boxes table and support matrix.

- **`package.list` is `tvb-<board>`'s file list**: mode, repo file, install path, at Debian's paths
  (`/usr/lib/...`, never `/usr/local`); a `link <target> <dest>` line makes a symlink.
- **Firmware is the vendor's, from the board's stock image:** built for that chip, it is the build
  known to work with it. It ships in `tvb-firmware-<chip>`, from `firmware/common/<chip>/` with a
  `firmware.conf` and a `package.list`, which the board depends on from its first board on. A file
  keeps its name from the stock image, or from its source; `package.list` maps it to the name the
  driver asks for. Variants that share one stock name are named for what sets them apart.
  1. A newer build wins, wherever it comes from, Debian or another vendor's SDK; so does one that
     works where the stock one fails on our driver. The package's `README.md` says which, with
     versions.
  2. Two boards' stock images with different builds of one file are their own question, settled per
     file in that `README.md`.

- **Where firmware installs:** a chip's settings variants, the Seekwave RF NV files by antenna
  wiring, ship in the chip's package, and the board's `package.list` picks one with a `link` line. A
  board ships a blob only when two boards' factory images hold different bytes for it. The kernel
  takes the first match:

  | Searched | Directory                             | Owner                             |
  | -------- | ------------------------------------- | --------------------------------- |
  | 1st      | `/usr/lib/tvb/firmware`               | `tvb-<board>`: overrides, `link`s |
  | 2nd      | `/usr/lib/firmware/updates/<kernel>/` | the box's admin, by hand          |
  | 3rd      | `/usr/lib/firmware/updates/`          | `tvb-firmware-<chip>`             |
  | 4th      | `/usr/lib/firmware/`                  | Debian's `firmware-*`             |

  The first is `firmware_class.path` on every board's command line. No path has two owners.

- **Never bake in user preferences or big compiled userspace.** An HDMI `video=` pin would cap every
  4K TV to suit one PC monitor; a Kodi/ffmpeg-MPP stack would break the property that makes this
  repo cheap. Document those as recipes.

## Verify the image offline

Cheaper here than on the box. Attach the built image and check:

- **Loaders byte-identical** to `firmware/<board>/factory_idbloader.bin` (sector 64) and
  `firmware/<board>/uboot.itb` (16384) — `dd` + `md5`.
- **DTB** matches `firmware/<board>/board.dtb` at `/usr/lib/tvb/board.dtb`.
- **`/usr/lib/tvb/`** populated: `board-name`, `board.dtb`, the loaders.
- **Filesystem clean** — the build's `fsck.ext4 -fn` gate must have passed.

Validation is the last gate, and it has its own criteria list.
