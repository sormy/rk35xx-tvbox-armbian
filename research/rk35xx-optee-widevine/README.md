# Restoring OP-TEE, and whether Widevine could follow

Family-wide. Opened 2026-09-11 while establishing what reads `SSKR` — the answer is nothing, because
our FIT carries no TEE; the kernel's OP-TEE probe fails, `api uid mismatch`, `-22`. This is the file
for whether that is worth changing.

## What the stock image holds

Measured 2026-09-11 by searching a full factory eMMC dump.

- ✅ **Widevine ran on stock.** `init.svc.vendor.drm-widevine-hal: running`, alongside
  `com.google.android.widevine.lazy.apex`, `libwvdrmengine`, `liboemcrypto.so` and
  `latest-component-updated-widevine-cdm`.
- ✅ **Three trusted applications** in `/vendor/lib/optee_armtz/`, and `HSTO` — the OP-TEE signed-TA
  magic — appears 4 times:

  | TA                                     | binary references |
  | -------------------------------------- | ----------------- |
  | `0b82bae5-0cd0-49a5-9521-516dba9c43ba` | 2                 |
  | `258be795-f9ca-40e6-a869-9ce6886c5d5d` | **5**             |
  | `481a57df-aec8-47ad-92f5-eb9fc24f64a6` | 2                 |

  The UUIDs appear as text only in the ext4 directory entry, so they were counted in binary form
  instead: a client library that opens a TA carries its UUID as 16 bytes. `258be795…` having more
  than double the others is the signature of a TA something links against.

- ✅ **The L3 path is present too** — `libl3oemcrypto.cpp`, `level3_oemcrypto_initialization_error`,
  `com.youtube.widevine.l3`. Every device ships L3, so this neither confirms nor rules out L1.
- ❓ **Whether L1 was provisioned and working** on the stock firmware. Strings cannot say.

## Restoring a TEE is the easy half

The factory chain ran OP-TEE `fwver v1.06`, and `rkbin` ships the matching `rk3528_bl32_v1.06.bin`.
`build-uboot.sh` passes `BL31` only; adding `TEE=` puts OP-TEE back in the FIT. ❓ What that does to
a working box — memory reservations, boot time, whether anything regresses — has not been tried.

## Why Widevine would not follow

- The keys in `SSKR` are sealed by the TA that provisioned them. Preserving the sectors preserves a
  sealed blob, not a usable key; only that TA can unseal it.
- 🟡 **The sealing key is in the chip, not the image.** ✅ The factory trees carry
  `secure-otp@ffcd0000`, separate from the `otp@ffce0000` mainline reads for the cpuid MAC, and 🟡
  OP-TEE seals secure storage under a hardware unique key. So the blob would decrypt on this box if
  the TEE stack were restored — it is chip-bound, not image-bound, and cannot move to another unit.
  Restoring the Android image is therefore not the blocker; the missing piece is a consumer.
- L1 needs the vendor's Widevine TA, and a CDM that can talk to it. ❓ No L1-capable Widevine CDM is
  known to exist for Linux — Chromium's aarch64 CDM is L3-only.
- L1 also needs the secure video path: secure memory allocator, `rkvdec` in secure mode, secure
  display. That is Android media-framework plumbing, not mainline DRM/V4L2.
- **L3 needs none of this.** It is a userspace CDM with no TEE and no secure storage, and is what
  gets DRM streaming working on ARM Linux — capped at SD/720p by the services, not by the box.

## What it would actually buy: probably nothing

DRM level gates resolution on the commercial streaming services, not playback. Decode is ✅ to 8K
for H.264/HEVC/VP9 regardless, and local files, Jellyfin/Plex, Kodi, IPTV and YouTube are
unaffected.

And those services gate HD on a per-model certification allowlist, not on Widevine level alone. ✅
This box reports `ro.product.brand: RockChip` and `ro.product.model: H96_Max_3518_TS` — a reference
design identity, not a certified consumer model — so it would have been served SD on stock Android
too, TA or no TA. Weigh that before spending any effort here.

## Open

- Which of the three TAs is Widevine. Extract them from a dump and check which UUID
  `liboemcrypto.so` opens, rather than inferring from reference counts.
- Whether a TEE can be added to our FIT without regressing a working box.
- Whether any Linux CDM can reach an L1 backend at all. If not, the rest is moot and this file
  closes.
