# Repo layout

Every folder named for what it holds, every patch beside what it patches, every doc current or gone.
Repo paths only: no box sees them.

## Folders

Hand-written sources under `src/`; the pipeline's steps stay at the top. Decided 2026-10-22.

| Today                                                               | To                        |
| ------------------------------------------------------------------- | ------------------------- |
| `firmware/<board>/`                                                 | `src/boards/<board>/`     |
| `firmware/common/<chip>/`, `modules/<x>.conf`, `patches/<x>/`       | `src/chips/<chip>/`       |
| `firmware/common/`, the rest                                        | `src/common/`             |
| `build-*-dts.sh`, `build-rockchip-loaders.sh`, `build-firmware*.sh` | `src/tools/board/`        |
| `scripts/aml-*.py`                                                  | `image/`, its only user   |
| `patches/<kernel-wide topic>/`                                      | `kernel/patches/<topic>/` |
| `README_AMLOGIC.md`                                                 | stays beside `README.md`  |

A chip is one folder: its out-of-tree driver's pin, its patches, in-tree or not, its firmware, and
one README. A board with a known chip touches only `src/boards/<board>/`; a new chip is one
`src/chips/<chip>/`. `kernel/patches/` keeps what is not a chip's: SoC support, vendor fixes, DRM.
`stock/`, `research/`, `docs/` and `keyring/` stay where they are.

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
