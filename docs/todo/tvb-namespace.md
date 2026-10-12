# The `tvb-` namespace

Every installed name carries `rk35xx-`, which is SoC-specific in a repo that now carries an Amlogic
board, and collides on a box with Armbian's own `vendor-rk35xx` kernel files. It becomes `tvb-`. A
prefix stays: our files share `/usr/local/sbin`, `udev`, `systemd` and `modprobe.d` with the distro,
and the updater prunes by it.

## What `rk35xx` means today

| Meaning       | Where                                                      | Action                   |
| ------------- | ---------------------------------------------------------- | ------------------------ |
| our namespace | every installed name, the repo files mirroring them        | `tvb-`                   |
| the SoC       | `BOARD_FAMILY=rk35xx`, `docs/todo/rk35xx-*.md`, the kernel | kept                     |
| repo, tools   | `rk35xx-update`, `rk35xx-deploy`, `rk35xx-tvbox-armbian`   | `tvb-*`, `tvbox-armbian` |
| history       | `worklog*.md`, `research/`                                 | untouched                |

Namespace includes the paths (`/usr/local/share/rk35xx/`), the numbered drop-ins
(`99-rk35xx-vpu.rules`), the IR DKMS package (`rockchip-pwm-remotectl-rk35xx`) and the updater's
staging suffix (`.rk35xx-new`).

## A literal name, not a variable

`BOARD_PREFIX` goes, and no `@NS@` placeholder replaces it: the namespace is one fixed word, and a
literal name greps. Gone with it: four `board.conf` lines, the updater's `P=`, and the `AGENTS.md`
sentence deriving names from it.

## Shared payload lists first

Most of the spread is each board's `payload.list` repeating the shared entries.

| List                            | Holds                                                   | Entries |
| ------------------------------- | ------------------------------------------------------- | ------: |
| `firmware/common/payload.list`  | every board: first boot, board name, DTB hooks, updater |       7 |
| `firmware/common/rk35xx.list`   | every Rockchip board                                    |      17 |
| `firmware/<board>/payload.list` | that board's own                                        |    rest |

`build-image.sh` and the updater read the three in that order, the family list by `BOARD_FAMILY`; no
include syntax. A new board stops copying ~25 shared lines, and the rename touches each shared entry
once.

## Ordering on the box

Checked in the R69 image:

- ✅ `/etc/kernel/postinst.d`: `tvb-dtb-persist` still sorts before Armbian's
  `xx-initramfs-cleanup`.
- 🟡 udev: `99-tvb-vpu.rules` moves from before `99-systemd.rules` to after it. It sets permissions
  only.

## Migrating a deployed box

`sudo rk35xx-update --pull` runs the **old** script against the **new** repo. Without `BOARD_PREFIX`
it stops at `board.conf must set BOARD_PREFIX`, after the pull and before touching anything. The
migration is one second command:

```sh
sudo /usr/local/share/rk35xx/repo/tvb-update      # on the box; the R69's checkout is under share/r69
```

Keeping `BOARD_PREFIX=tvb` for a transition instead lets the old script finish, but with `tvb-*`
installed beside `rk35xx-*` and the old units still running.

`tvb-update` migrates, idempotently:

1. note the enabled `rk35xx-*.service` units, disable and delete them, enable their `tvb-*` twins;
2. move `/usr/local/share/rk35xx/` to `/usr/local/share/tvb/` — checkout, known-good DTB,
   `board-id`;
3. move `/var/lib/rk35xx-firstboot.done`, so first boot does not rerun; delete the image-build
   drop-in that enables `rk35xx-firstboot.service`;
4. delete `rk35xx-*` by pattern, only under the directories we install into — `/usr/local/sbin`,
   `/etc/{systemd,udev,apt,kernel,modprobe.d,modules-load.d}`,
   `/usr/lib/systemd/system-{sleep,shutdown}` — never `/boot` or `/lib/modules`;
5. `dkms remove` `rockchip-pwm-remotectl-rk35xx`; the new package builds in the usual step;
6. point the checkout's `origin` at the renamed repo.

## Commits

1. **Shared payload lists.** Done when all four images build with identical file lists and contents.
2. **The rename:** `git mv`, a scripted replace outside history, and the migration. Done when:
   - all four images match their pre-rename builds, names mapped `rk35xx-` to `tvb-`;
   - one box survives one update, one reboot, and one kernel reinstall with the DTB intact;
   - `systemctl --failed` is empty and the VPU nodes keep their permissions.
3. **Repo rename** on GitHub, then `REPO_URL`.
4. **Less code, later:** drop the `r69-` migration block and the `share/r69` special case. The repo
   is public, so the `rk35xx-` step stays.

## Decide

- Rockchip-only pieces — the IR driver, vendor storage, the VPU rules: `tvb-` like the rest (one
  mechanical rule, what a board installs is already chosen by its lists), or a Rockchip name
  (`rockchip-pwm-remotectl-rk35xx` unchanged, no DKMS migration)?
- The repo name: `tvbox-armbian`.
