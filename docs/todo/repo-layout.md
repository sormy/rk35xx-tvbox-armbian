# Repo layout

Every folder named for what it holds, every patch beside what it patches, every doc current or gone.
Starts once the overlay and `upstream/` are removed (`TODO.md`), so nothing is moved only to be
deleted. Repo paths only: no box sees them.

## Folders

| Today                                      | To                                 |
| ------------------------------------------ | ---------------------------------- |
| `firmware/<board>/`                        | `boards/<board>/`                  |
| `firmware/common/<chip>/`                  | `chips/<chip>/`                    |
| `patches/<kernel topic>/`                  | `kernel/patches/<topic>/`          |
| `patches/<driver>/`                        | `modules/patches/<driver>/`        |
| `patches/u-boot/`                          | `uboot/patches/`                   |
| `patches/<host tool>/`, `src/<tool>/`      | `tools/<tool>/`, patches beside it |
| `build-dtc.sh`, `build-rktools.sh` and kin | `tools/<tool>/build.sh`            |
| `scripts/`                                 | `tools/`, by what each script does |
| `README_AMLOGIC.md`                        | a doc in `docs/`, or `README.md`   |

The repo root ends with `build.sh`, the READMEs, `AGENTS.md`, `TODO.md` and folders. Build outputs
(`images/`, `log/`, `uboot-build/`, a tool's built binary) go under `build/`, which is gitignored
whole.

## Docs

Each doc against the index in `AGENTS.md`: current, it stays; describing a removed path, it goes; a
finished experiment, it moves to `research/`. Worklogs stay whole: they are history.

## How

- One move per commit, by `git mv`, with every reference in the repo fixed in the same commit.
- After each: `./build.sh release` and a diff of the images' payload files against the commit
  before. Only paths in the repo move; a file on a box never does.
