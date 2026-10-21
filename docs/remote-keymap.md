# Remote keymaps: IR and BLE are two keymaps, not one

A dual-mode handset is two independent keymaps wearing one shell. Validating one proves nothing
about the other, and on these boxes they genuinely disagree.

| Transport | Node                   | Keymap from              | Ours?       |
| --------- | ---------------------- | ------------------------ | ----------- |
| IR        | `/dev/input/ir-remote` | `ir_keyN` in `board.dts` | in the tree |
| BLE       | `/dev/input/bt-remote` | the handset's HID usages | `hwdb` only |

`rockchip-pwm-remotectl` drives the IR node; `hid-input` drives the BLE ones.

Over IR the box decodes a vendor scancode and looks it up in a table **we** ship. Over BLE the
handset declares its own HID usages and the kernel translates them faithfully — including into keys
nobody wants. That is why one button can be `KEY_BACKSPACE` over IR and `KEY_MENU` over BLE.

Commands run on the box; a block using `ssh` runs on the host.

## What correct means

Judge against the **printed label**, not against what the transport happens to send. A defensible
HID usage that produces the wrong key is still the wrong key.

- [ ] every button produces an event
- [ ] no button reports `KEY_UNKNOWN`
- [ ] no two buttons share a keycode
- [ ] the keycode matches the icon — `KEY_MENU` on a ⌫ key is a fault, not a quirk
- [ ] where the board has both transports, the two agree button for button
- [ ] the resulting table is recorded in `docs/<board>/board.md`

Run it once per transport. On a board with no IR receiver, BLE is the only pass; on a board with
both, a handset that works over IR can still have dead buttons over BLE.

## Capturing

Record the scancode as well as the keycode — the scancode is what a remap matches on.

```sh
sudo evtest /dev/input/ir-remote          # IR
sudo evtest /dev/input/bt-remote          # BLE; pair and trust first, or the node does not exist
sudo evtest /dev/input/bt-remote-consumer # BLE; media and volume usually arrive here instead
```

A BLE handset pairs as three HID interfaces — keyboard, consumer control, mouse — each its own node.
Which one carries a given button differs per remote, so capture from both key-bearing nodes before
calling a button dead.

Press every button and read the pairs:

```
type 4 (EV_MSC), code 4 (MSC_SCAN), value c0040
type 1 (EV_KEY), code 139 (KEY_MENU), value 1
```

**`MSC_SCAN` is the gate.** If it is there, the button is remappable. If a button emits only
`EV_KEY` with no scancode, `hwdb` has nothing to match and cannot help.

BLE scancodes are raw HID usages: `c…` is the consumer page, `7…` the keyboard page. Usages in the
spec's reserved ranges are exactly the ones that arrive as `KEY_UNKNOWN`, because `hid-input` has
nothing to map them to.

## Fixing IR

Edit the `ir_keyN` table in `board.dts` — the scancode-to-keycode pairs are plain data in the tree,
and the tree is the lowest layer that can express it.

## Fixing BLE with an hwdb override

The handset's HID descriptor is not ours, so the remap goes in `udev`'s keyboard database. Match on
the **model**, which is what the modalias carries:

```
# firmware/common/bt-remote.hwdb — the whole shipped file
evdev:input:b0005v2B54p1600*
 KEYBOARD_KEY_700aa=reserved
 KEYBOARD_KEY_c0011=menu
 KEYBOARD_KEY_c003b=prog2
 KEYBOARD_KEY_c003d=prog3
 KEYBOARD_KEY_c003e=prog4
 KEYBOARD_KEY_c0040=backspace
 KEYBOARD_KEY_c0041=ok
 KEYBOARD_KEY_c0056=prog1
 KEYBOARD_KEY_c008f=setup
```

Nine overrides for the bundled handset. Six rename a usage the kernel could not map at all; three
correct a usage it mapped to the wrong key.

| Scancode                        | Button          | Override        | Was           |
| ------------------------------- | --------------- | --------------- | ------------- |
| `c0011`                         | hamburger       | `menu`          | `KEY_UNKNOWN` |
| `c0056` `c003b` `c003d` `c003e` | four app keys   | `prog1`…`prog4` | `KEY_UNKNOWN` |
| `700aa`                         | voice, 2nd code | `reserved`      | ➖            |
| `c0040`                         | ⌫               | `backspace`     | `KEY_MENU`    |
| `c008f`                         | cog             | `setup`         | `KEY_GAMES`   |
| `c0041`                         | centre          | `ok`            | `KEY_SELECT`  |

⌫ and the cog were mapped, just wrongly: the handset sends consumer usage `Menu` for ⌫ and
`Media Select Games` for the cog. The voice key emits a second usage per press, which `reserved`
swallows.

Pick the keycode from the printed button, then check the name exists — `KEY_SETTINGS` does not, so a
cog is `KEY_SETUP`. `grep '^#define KEY_' /usr/include/linux/input-event-codes.h` is the list udev
accepts, lowercased and without the prefix.

The voice key itself is untouched: `c0221` is consumer _AC Search_ and already reports `KEY_SEARCH`.
Only its companion usage is deleted, so one press yields one event.

| Field   | Meaning                                            |
| ------- | -------------------------------------------------- |
| `b0005` | bus `0x0005`, `BUS_BLUETOOTH`                      |
| `v2B54` | vendor id, from the handset's PnP record           |
| `p1600` | product id                                         |
| `*`     | swallows the version and the capability-bit suffix |

These are **model** fields — the Bluetooth address appears nowhere in a modalias, so one entry
covers every unit of that model, and a board without that handset never matches.

That makes it tempting to ship family-wide. Don't. The entry matches on the model id but **remaps by
scancode**, and a shared id is not a shared button layout — OEMs reuse ids. List the file only in
the `package.list` of a board whose handset you actually captured, and add a board only after
capturing its remote too. `0x2B54` is not even in the USB vendor table, so an unrelated remote could
in principle carry it.

`=reserved` deletes an event rather than renaming it — the fix for a button that sends a second,
useless usage alongside a good one.

Get the vendor and product from BlueZ, in decimal:

```sh
sudo find /var/lib/bluetooth -name info | while read f; do sudo grep -E '^(Name|Vendor|Product)=' "$f"; done
```

### Installing it

**udev reads only the compiled `hwdb.bin`, never `hwdb.d/`.** `tvb-<board>` installs the file into
`/usr/lib/udev/hwdb.d/`, and udev's dpkg trigger rebuilds `/usr/lib/udev/hwdb.bin` with
`systemd-hwdb --usr update`. A plain `systemd-hwdb update` writes `/etc/udev/hwdb.bin` instead,
which masks the `/usr/lib` one from then on — always pass `--usr`. By hand, from the host:

```sh
ssh box 'sudo tee /usr/lib/udev/hwdb.d/60-tvb-bt-remote.hwdb >/dev/null' < firmware/common/bt-remote.hwdb
ssh box 'md5sum /usr/lib/udev/hwdb.d/60-tvb-bt-remote.hwdb'   # compare with the local file
ssh box 'sudo systemd-hwdb --usr update --strict'
```

**Check the checksum, every time.** A dropped ssh leaves a zero-byte source file, and nothing
complains: `systemd-hwdb` compiles an empty file happily, and until the next rebuild the
already-compiled `hwdb.bin` keeps answering queries correctly. The mapping then disappears at the
next rebuild — on someone else's box, months later.

Verify the match resolves before touching the handset — this needs no remote:

```sh
sudo systemd-hwdb query "evdev:input:b0005v2B54p1600e0000-e0,1,4,k71,72,73,ramlsfw"
```

### Reloading it

`KEYBOARD_KEY_*` is applied by udev's `keyboard` builtin when the device appears, so recompiling
alone leaves an already-connected remote on the old map. Two steps:

```sh
sudo systemd-hwdb --usr update                                # recompile /usr/lib/udev/hwdb.bin
sudo udevadm trigger --subsystem-match=input --action=change  # re-apply to live devices
```

`udevadm control --reload` does **not** do this — it reloads rules, not the hardware database.
Disconnecting and reconnecting the remote works too, and is the only option if the trigger does not
take. Then re-read the keycodes:

```sh
udevadm info /dev/input/bt-remote | grep KEYBOARD_KEY   # properties reached the device
sudo evtest /dev/input/bt-remote                        # the keycodes themselves
```

Two traps worth knowing: there is **no `60-keyboard.rules`** on current systemd — it was merged into
`60-evdev.rules`, which does the `hwdb --lookup-prefix=evdev:` import and the
`IMPORT{builtin}="keyboard"`. And a BLE handset that has gone idle stops advertising, so
`bluetoothctl connect` cannot raise it; only a button press can.

> Capture, query, reload onto a live device and the remapped keycodes read back off the handset are
> confirmed on the H96 Max 3518D, 2026-09-07; the `--usr` install and query on the H96 Max M20,
> 2026-10-20.
