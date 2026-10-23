# Repo layout

Every folder named for what it holds, every patch in `patches/`, every doc current or gone. Repo
paths only: no box sees them.

## Folders

Subject folders at the root, the pipeline's steps beside them; one mechanism per job. Decided
2026-10-22.

| Folder              | Holds                                                                 |
| ------------------- | --------------------------------------------------------------------- |
| `base/`             | `tvb-base`: what every box gets, laid out at install paths            |
| `boards/<board>/`   | `board.conf`, trees, loaders, and its own files under `rootfs/`       |
| `boards/common/`    | one folder a family, `rootfs/` taken whole by that family's boards    |
| `firmware/<chip>/`  | a chip's blobs and its driver's options, under `rootfs/`              |
| `modules/`          | out-of-tree driver pins, and the step packaging them                  |
| `patches/<target>/` | every deviation from an upstream, its README saying what upstream has |
| `tools/<tool>/`     | host tools; `tools/board/` for the board generators                   |

A board is a folder with a `board.conf`: no loop lists `boards/` by name.

**On the box: vanilla Debian plus packages.** A default goes under `/usr/lib` where the program
reads it, an `/etc` conffile only where it does not, and never into a file another package owns.
Locale and the first root-password login are image state, not packaged.

In order, one commit each:

| From                                        | To                                              |
| ------------------------------------------- | ----------------------------------------------- |
| `image/rootfs/` and the all-board files     | `base/`, packaged as `tvb-base`                 |
| `firmware/<board>/`                         | `boards/<board>/`                               |
| the family-shared files                     | `boards/common/<family>/`                       |
| `firmware/common/<chip>/`                   | `firmware/<chip>/`; `seekwave-fw` as `swt6621s` |
| `package.list`                              | `rootfs/` in each folder                        |
| `build-*.sh` but `build.sh`, and `scripts/` | `tools/board/`; `aml-*.py` to `image/`          |

Each step proven the same way: every package rebuilt identical, an image built. `stock/`,
`research/`, `docs/` and `keyring/` stay where they are.

The repo root ends with `build.sh`, the READMEs, `AGENTS.md`, `TODO.md` and folders. Build outputs
go under `build/`, which is gitignored whole.

## Docs

Each doc against the index in `AGENTS.md`: current, it stays; describing a removed path, it goes; a
finished experiment, it moves to `research/`. Worklogs stay whole: they are history.

## README

Generic only; everything family- or board-specific moves to a doc and stays one link away.

1. **The pitch**, two lines.
2. **Boxes**: one row a board, with a colour for its state (green works, yellow mostly, orange
   partly, red boots only), its SoC, its family's install doc, its Debian base, the kernel it runs
   and the next one offered, and its image's download link. Generated from the boards and the latest
   release, like the website's list.
3. **Install**: write the image, boot, first login, `tvb-install`, each one line; the family's
   medium and any one-time step in its install doc.
4. **Update**: `apt`.
5. **Contribute and report**, then build, credits, license.

Out to their own docs: the per-family install (`README_AMLOGIC.md` folds into the Amlogic one), the
no-SD-slot route, remote pairing, serial, recovery.

| Family    | Medium  | Why                                                         |
| --------- | ------- | ----------------------------------------------------------- |
| rk35xx    | SD card | the factory loader boots it                                 |
| Amlogic   | USB     | no SD slot on the M20; an environment update over OTG, once |
| Allwinner | SD card | 🟡 its boot ROM tries SD before eMMC and cannot boot USB    |

## How

- One move per commit, by `git mv`, with every reference in the repo fixed in the same commit.
- After each: `./build.sh release` and a diff of the images' payload files against the commit
  before. Only paths in the repo move; a file on a box never does.
