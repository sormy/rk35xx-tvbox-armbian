# Upstream sources

Every source TVBian builds from, and whether it moves on its own. The rule: **float what makes
trustworthy releases, pin what has one maintainer, no releases, or can brick a box.** A floating
source resolves at build time; the release notes name what it resolved to.

## Kernels

| Kernel         | Upstream              | Follows                                       |
| -------------- | --------------------- | --------------------------------------------- |
| `meson64`      | kernel.org stable     | newest longterm tag (`FOLLOW`)                |
| `meson64-next` | kernel.org stable     | newest stable tag; opt-in                     |
| `rk35xx`       | rockchip-linux/kernel | tip of `develop-6.1`, soaked                  |
| `rk35xx-next`  | rockchip-linux/kernel | tip of the newest `develop-*`, soaked; opt-in |

Mainline floats to tags: kernel.org's own releases. Rockchip tags nothing, so the vendor kernels
follow a branch tip, **soaked**: the newest commit at least 7 days old, so a commit pushed and
reverted within the week never ships. The vendor tip is worth following: the RK3528's HDMI PHY fix
reached `develop-6.1` and no tagged kernel. Moving a kernel to another series is a change in
`kernel/`, by hand.

## Out-of-tree drivers

| Driver       | Upstream                     | Follows            | Why                                 |
| ------------ | ---------------------------- | ------------------ | ----------------------------------- |
| `aic8800`    | radxa-pkg/aic8800            | newest release tag | how Radxa ships its own package     |
| `swt6621s`   | retro98boy/seekwave-swt6621s | pinned `COMMIT`    | one maintainer, untagged            |
| `meson-venc` | ray38080289/meson-sm1-codecs | pinned `COMMIT`    | the kernel imports a snapshot of it |

`meson64`'s decoder is the same repository at the same commit, imported with 18 patches ported onto
it, so the encoders and the decoder move together, as a porting job.

## Bootloaders

| U-Boot             | Upstream      | Follows      | Built by         |
| ------------------ | ------------- | ------------ | ---------------- |
| M20, chain-loaded  | u-boot/u-boot | pinned `TAG` | `uboot/*.conf`   |
| RK3528 `uboot.itb` | u-boot/u-boot | pinned tag   | `build-uboot.sh` |

Pinned: a bad bootloader can leave a box with no way back short of maskrom. A new tag goes onto a
box before its pin moves.

## Firmware

Copied into `firmware/common/<chip>/`, each with a README naming origin and version: the vendor's
stock build by default, a newer one from any source where it is shown to work. It moves by hand. The
AIC8800 set comes from Radxa's tree at the driver's commit and moves with the driver.

## Userspace and the build

| Source                    | Follows                                  |
| ------------------------- | ---------------------------------------- |
| Debian packages           | the stable suite, through `apt`          |
| the build container       | `debian:<stable>`, rebuilt as it changes |
| `dtc`, `e2tools`          | pinned release tag                       |
| `rkdeveloptool`, `gxlimg` | pinned commit                            |

Host tools carry our patches and touch boards directly; they move by hand.

## When a floating source breaks

A floating source whose new release breaks our patches fails that week's build, and nothing
publishes. `COMMIT=` in its conf holds it at the last good commit until the patch is rebased, then
comes out again.

## Moving a pin

The `repin` workflow, run by hand (`gh workflow run repin`), does step 1 for every pinned source at
once and opens one pull request: each pin at its newest commit or tag, old and new linked, a source
whose patches no longer apply left out and named. The PR's check is the build; the box test and the
merge stay manual.

1. Change `COMMIT=` or `TAG=` in its conf, or the variable in the host script.
2. Rebase any patch that no longer applies.
3. Build, and run the result on a box that carries that hardware.
4. Commit the pin with the box it ran on in the message.
