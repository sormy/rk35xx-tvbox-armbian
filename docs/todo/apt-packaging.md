# Packaging the payload as local `.deb`s: blocked on the build host

Opened 2026-09-14. Evaluated, not started.

Shipped state: `firmware/<board>/payload.list` is copied verbatim — into the image by
`build-image.sh` (`e2cp`), onto a running box by `rk35xx-update`. Around thirty entries per board.

## What packaging would buy

| Win                                      | Packaging-only | Route today           |
| ---------------------------------------- | -------------- | --------------------- |
| removals computed on rename              | **yes**        | —                     |
| `apt upgrade` updates the overlay        | **yes**        | —                     |
| the box can name its own commit          | no             | a version-stamp entry |
| `platform_install.sh` survives reinstall | no             | `dpkg-divert`         |
| u-boot guard from image build            | no             | a `preferences.d` pin |
| reload only on a changed file            | no             | the `[5/6]` block     |

Row 2 costs an apt repo: hosting, a GPG key, key distribution, CI.

Row 1 is **prospective only**. The legacy `r69-*` paths are owned by no package, so `dpkg` will
never remove them and `migrate()` in `rk35xx-update` stays until every box is reflashed. What
packaging removes is the need to _extend_ that list on the next rename.

A `-dkms` package is a wash. `rk35xx-firstboot` skips a module the kernel has in-tree, continues
past a failed build, and refetches sources in place; that logic moves to the postinst, not away.

## The build host cannot install a package into the image

`build-image.sh` writes ext4 offline with `e2tools` on macOS — no `chroot`, `qemu`, `docker`, `lima`
or `multipass` in the build path. `dpkg-deb` can **build** a `.deb` there; nothing can **unpack**
one with a coherent `/var/lib/dpkg`.

| Way out                         | Cost                                |
| ------------------------------- | ----------------------------------- |
| `.deb`s installed at first boot | the image stops booting configured  |
| `e2cp` plus a hand-written db   | two mechanisms, one of them fragile |
| a Linux container in the build  | a new build-host dependency         |

Only the DKMS builds are deferred today. Deferring the payload too puts the configured state behind
a step that can fail, on a board with no SD slot and serial-only recovery.

## Conffile semantics work against the update

18 unique payload targets sit under `/etc`. `dpkg` treats a pre-existing file at a conffile path as
locally modified and non-interactively keeps what is on disk, so an update would no-op on exactly
the drop-ins that changed. `rk35xx-update` overwrites unconditionally, which is the intent.

15 of the 18 have a `/usr/lib` search path and could move there. The three that cannot:
`/etc/apt/apt.conf.d/99-rk35xx-boardname` and both `/etc/kernel/postinst.d/` hooks.

## Do these three now; they need no packaging

1. **`dpkg-divert` the `platform_install.sh` override.** A divert survives the u-boot package being
   reinstalled or the hold being lifted; today only the hold defends it. 🟡 that the path is
   package-owned — confirm on the box:

   ```sh
   dpkg -S /usr/lib/u-boot/platform_install.sh
   ```

2. **Replace the first-boot `apt-mark hold` with `/etc/apt/preferences.d/99-rk35xx-uboot`.** A hold
   cannot be set offline — it lives in `/var/lib/dpkg/status` — so the guard depends on first boot
   succeeding. `Pin-Priority: -1` on `linux-u-boot-*` blocks upgrade and explicit install and ships
   as a payload entry, applying from image build. `docs/apt-upgrade.md` changes in the same pass:
   `apt-cache policy`, not `apt-mark showhold`.

   ```sh
   apt-get -s full-upgrade | grep -i u-boot     # on the box: nothing selected
   ```

3. **Stamp the installed version.** `rk35xx-deploy` rsyncs with `--exclude=.git`, so a deployed box
   cannot say what it runs. The stamp is written by the side that has the commit — the host in
   `rk35xx-deploy`, the checkout in `rk35xx-update --pull`.

## Revisit packaging when

- **An apt repo is wanted.** Row 2 is the only transformative win and the only one needing `.deb`s.
  Against it: ❓ whether an overlay that can soft-brick should upgrade unwatched.
- **The image build moves to Linux or CI.** That deletes the block, leaving the generator plus the
  conffile move.

Either way, generate `control` and the install manifest from `payload.list` + `board.conf`, so
adding a board stays a directory.

## Done means

This file says which condition fired and what was decided, or the three items shipped and packaging
was declined with the reason.
