# Banning a display mode with an EDID override

A local, per-display workaround for when a screen advertises a mode that something insists on
picking and should not. It edits the display's own EDID and loads it from the kernel command line.

## When you need this

The symptom is **not** a broken display — it is a _disagreement about which mode to use_. Reach for
this only when all of these hold:

- the display works correctly in its native mode
- **some** clients are fine and **others** are black or corrupt, on the same box, at the same time
- the failing client is choosing a different mode from the working ones

That combination is the signature. A fault that affects _everything_ — console included — is a
driver or hardware problem, and an EDID edit will only hide it badly. Check `Update mode to …` in
`dmesg` and the CRTC size in `modetest -M rockchip -p`: if the failing client set a mode the working
ones did not, this doc applies. If everything is on the same mode and still broken, it does not.

**Why the disagreement happens.** DRM offers a mode _list_, and clients pick from it however they
like. There is no rule that they must honour the `preferred` flag:

| Client                    | Picks                                          |
| ------------------------- | ---------------------------------------------- |
| fbcon, `kmscube`, Android | the connector's `preferred` mode               |
| `glmark2-es2-drm`         | the **largest area** mode; ignores `preferred` |

So a TV that advertises both 3840x2160 (its native panel, marked preferred) and 4096x2160 (DCI 4K,
6% more pixels) splits its clients in two. The ones picking by area select a mode the panel cannot
display and render a healthy frame rate onto a black screen.

## Why the obvious fixes do not work

| Attempt                                  | Why not                                                                                                                                                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `video=HDMI-A-1:3840x2160@60`            | pins **fbcon only**; a KMS client still modesets to its own choice                                                                                            |
| A device-tree property                   | none exists — the mode list is built from EDID, not the tree                                                                                                  |
| Kernel command line                      | no parameter removes a single mode; `video=…d` disables the whole connector                                                                                   |
| Stock `/lib/firmware/edid/1920x1080.bin` | replaces the EDID **wholesale**, so the display's real detailed timings go too — on an LG 4K TV this gave vertical colour bars, worse than the original fault |
| Patching the client                      | `glmark2` has no connector/CRTC/mode option at all; `--size` sets the render surface, not the scanout mode                                                    |

What is left is to change what the connector advertises, starting from **the display's own EDID** so
its timings survive.

## Why this must stay local

The override encodes one screen's data. Ship it in an image and every other user gets a stranger's
television. Keep it in a `u-boot-menu` drop-in on the box that needs it, and treat the file as
disposable — a different TV, or a firmware update to the same TV, invalidates it.

It is also a **workaround, not a fix**. It papers over a client that selects modes badly. Prefer
using a client that honours `preferred` (`kmscube` over `glmark2-es2-drm`) and reach for this only
when you specifically need the badly-behaved one — for example to get a benchmark number comparable
with another board.

## Recipe

**1. Dump the real EDID** — as root; a normal user reads 0 bytes:

```sh
sudo od -An -tx1 -v /sys/class/drm/card0-HDMI-A-1/edid | tr -d ' \n'
```

**2. Remove the mode from every place it is advertised.** This is the step that catches people out:
4K modes are listed **twice**, and deleting one leaves the mode present.

| Where                                            | What to remove                                      |
| ------------------------------------------------ | --------------------------------------------------- |
| CEA extension, Video Data Block (tag 2)          | the VICs — 98-102 are 4096x2160 @ 24/25/30/50/60    |
| CEA extension, HDMI VSDB (tag 3, OUI `03 0c 00`) | the `HDMI_VIC` entries — HDMI VIC 4 is 4096x2160@24 |

In the VSDB the `HDMI_VIC_LEN` is the top three bits of a byte near the end, followed by that many
one-byte VICs; decrement the count and drop the byte.

**3. Fix up the block after every deletion**, or the kernel rejects the blob:

- the data block's own length — low 5 bits of its tag byte
- the CEA block's **DTD offset** (byte 2) — shrink by the number of bytes removed
- pad the tail with zeros so the block stays exactly 128 bytes
- recompute the checksum: the last byte makes the block sum to 0 mod 256

Leave **block 0 untouched** — the real timings and the preferred mode live there.

**4. Install and select it**, on the box:

```sh
sudo install -m 644 mytv-no-dci.bin /lib/firmware/edid/mytv-no-dci.bin
echo 'U_BOOT_PARAMETERS="$U_BOOT_PARAMETERS drm_kms_helper.edid_firmware=HDMI-A-1:edid/mytv-no-dci.bin"' | sudo tee /etc/u-boot-menu/conf.d/zz-edid.conf
sudo u-boot-update
```

The kernel warns this is deprecated in favour of `drm.edid_firmware`; both work.

**5. Verify:**

```sh
sudo dmesg | grep 'Got external EDID'          # confirms it loaded
sudo modetest -M rockchip -c | grep -c 4096    # should be 0
```

## Reversing it

Remove `/etc/u-boot-menu/conf.d/zz-edid.conf` and run `sudo u-boot-update`, or clear it live with no
reboot:

```sh
echo "" | sudo tee /sys/module/drm_kms_helper/parameters/edid_firmware
echo detect | sudo tee /sys/class/drm/card0-HDMI-A-1/status
```

## Worked example

An LG 4K TV advertised eight 4096x2160 variants. Removing CEA VICs 98-102 left **two** still listed
— the HDMI VSDB was advertising `HDMI_VIC` 1-4, and 4 is 4096x2160@24. Dropping that as well (VIC
list 1-4 → 1-3, block length 14 → 13, DTD offset 103 → 102, checksum recomputed) cleared the list.
Every client then agreed on 3840x2160, because "largest area" and "preferred" finally named the same
mode.
