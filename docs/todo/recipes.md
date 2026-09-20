# Composing a board from recipes instead of two folders

Opened 2026-09-20. Evaluation, nothing built. Today a board is `firmware/common/` plus
`firmware/<board>/`; the question is whether it should instead be a named set of recipes, each
owning one capability, with the board config listing which it takes.

## Where the two-folder shape strains

Measured across the four boards in the tree:

|                                       |     |
| ------------------------------------- | --- |
| payload entries, all boards           | 117 |
| unique sources behind them            | 64  |
| sources used by more than one board   | 28  |
| entries that are therefore repetition | 53  |
| `BOARD_*` variables defined anywhere  | 19  |
| of those, used by exactly one board   | 6   |

`common/` answers "shared by someone", not "shared by whom". Eleven of its files land on three of
the four boards and are wrong on the fourth — they are a Rockchip recipe written as repetition in
three `payload.list`s. Six single-use `BOARD_*` variables are the same strain in `board.conf`: a
second SoC family arrived and the two tiers had nowhere to put what only it needs.

## The recipes the data already implies

Grouping the 64 sources by which boards take them produces these, with no judgement applied:

| Recipe              | Boards | Holds                                                                                              |
| ------------------- | :----: | -------------------------------------------------------------------------------------------------- |
| `core`              |   4    | the updater, first boot, board naming, DTB persistence                                             |
| `rockchip`          |   3    | vendor storage, platform-install, watchdog, VPU and input rules, LED hooks, MAC pinning, BT rfkill |
| `rockchip-boot`     |   3    | factory idbloader and `uboot.itb`, and the two vars naming them                                    |
| `seekwave-swt6621s` |   2    | chip firmware, module options, the DKMS fetch                                                      |
| `ir-remotectl`      |   2    | the PWM remote-control DKMS and its blacklist var                                                  |
| `powerkey`          |   3    | one destination, two variants — suspend, or ignore                                                 |
| `mt7668`            |   1    | chip firmware, the DKMS fetch, the staged base packages                                            |
| `identity`          |  each  | `board-id`, `board-name`, `board.dtb`, `mac-oui`                                                   |

Only `identity` is genuinely per-board. Everything else is a property of a chip, an SoC family or a
fitted part — which is what a recipe name would say and a folder name cannot.

## What a board config becomes

A list plus the data only that board has:

```sh
RECIPES="core rockchip rockchip-boot seekwave-swt6621s powerkey:ignore"
```

The win is that a board stops being able to silently miss a file. Adding a chip to a second board
becomes adding a word, and the removal list that `migrate()` maintains by hand becomes derivable —
the recipes a board no longer takes name exactly the paths to delete.

## What the model has to answer first

- **Two recipes, one destination.** `powerkey` already has two variants writing the same path.
  Either recipes are exclusive per slot, or last-wins by list order, and the second needs the order
  to be meaningful, which it is not today.
- **Where conditional `BOARD_*` vars live.** `BOARD_DKMS_FETCH`, `BOARD_IR_BLACKLIST`,
  `BOARD_APT_DEBS` belong to a recipe, not a board — but `board.conf` is sourced as shell, so a
  recipe contributing variables means composing shell fragments, and two recipes appending to the
  same variable is a merge, not an assignment.
- **The hooks.** Every board defines `board_stage_dkms` and `board_image_tweaks`. Those are the
  parts recipes would most want to own, and they are functions, so composition means calling several
  in order rather than defining one.
- **Removals still cannot be derived for deployed boxes.** A box that predates the change has files
  owned by no recipe. `migrate()` stays until every box is reflashed, exactly as `apt-packaging.md`
  found for packaging.

## What it costs

`AGENTS.md` claims adding a board is data, one directory, no code. Recipes keep that true and make
it truer for the second board with a given chip — but they add an indirection that has to be read
before anyone can tell what lands on a box, where today `payload.list` says so literally.

At four boards and two SoC families the repetition is 53 entries. That is enough to feel and not
obviously enough to pay for a composition engine, its conflict rules and its ordering rules.

## Decide when

- **A third SoC family arrives, or a second board takes `mt7668`.** Either makes the chip-versus-
  board distinction load-bearing rather than tidy.
- **`common/` needs a third tier.** The moment something is shared by two boards that are not the
  same family, the folder name stops describing it and the workaround is a per-board copy.

## Done means

This file names the trigger that fired and the decision, or says the two folders were kept and why.
