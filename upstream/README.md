# Device trees, for upstreaming

A board tree as a diff against that box's own factory tree. `<board>/armbian.patch` and
`<board>/header.dts` are the only files edited by hand; `./build.sh` regenerates the rest, including
the submission itself, and verifies it.

## Process

1. Carve the DTB from the eMMC dump, never off a running box — u-boot rewrites the tree it hands to
   Linux. Find it by its `d00dfeed` magic in the `boot` partition. → `stock/<board>/board.dtb`
2. Decompile: `tools/dtc/dtc -I dtb -O dts -P -n` (`-P` phandles → `&label`, `-n` drops
   `__symbols__`).
3. Edit into the Armbian tree; comment each change with the consumer that needs it. Then:
   ```sh
   cd <board> && diff -u --label board.dts --label armbian.dts board.dts armbian.dts > armbian.patch
   ```
4. Build its DTB — this is what boots — and copy it, with its source, over
   `firmware/<board>/board.dtb` and `board.dts`. **Needed for overlay mode**, where that pair is
   what images ship and what `rk35xx-update` installs; `firmware/` is the only tracked copy of this
   tree, everything under `upstream/` being generated. An upstreamed board gets its DTB from the
   kernel package instead and never reads `firmware/`.
5. `scripts/gen-overrides.py` re-expresses it as `/delete-node/` + `&label { }` over the vendor's
   reference dtsi, under `<board>/header.dts`. That output, `armbian-native.dts`, is the file that
   gets submitted.
6. Verify both describe the same hardware. Every line is compared, phandle values included:
   `scripts/remap-phandles.py` translates the native tree's to the patched tree's by node path
   rather than dropping them, so the diff fails unless every node carries the same phandle and every
   `&label` beside it resolves to the same node. Node order is the only thing left free. Ahead of
   it, `scripts/check-refs.py` proves no reference survived as a bare number — the two trees number
   their nodes differently, so such a number is the same text in both while naming a different node
   in each, and no diff can see it.
   ```
   VERIFIED: native tree is content-identical to the patched tree
   ```

Everything but step 3 is `./build.sh`; the submission is generated, so there is no second copy to
forget to update.

**The overrides carry no comments.** They describe the vendor's board, and the vendor shipped a blob
with no reasons in it — asking for one comment per block asks for reasons that do not exist, and the
ones written that way described the wrong node about as often as the right one. What _is_ knowable
is the departure from the factory tree, because that is `armbian.patch`: those go in `header.dts`,
one line each, and the commit message points there rather than repeating them.

## Files

One directory per board, named after the installed dtb — `r69-xr821/`, `h96max-zx/`. Two files are
source; the rest is generated and gitignored.

| File                      | What                                                 |
| ------------------------- | ---------------------------------------------------- |
| `armbian.patch`           | **source** — the grafts, against the factory tree    |
| `header.dts`              | **source** — SPDX and the board's provenance block   |
| `board.dtb` / `board.dts` | factory blob and its decompile                       |
| `armbian.dts` / `.dtb`    | patch applied                                        |
| `armbian-consts.dts`      | `dt-bindings` names instead of hex                   |
| `armbian-native.dts`      | **the submission** — header plus generated overrides |
| `armbian-native.dtb`      | built from it, gated against `armbian.dtb`           |

## Why a diff

The vendor ships a binary, so the factory tree is the specification and the reviewable artifact is
what we change about it. `board.dts` recompiles byte-identical to the factory blob; the explicit
`phandle` properties are what make that true and must stay.

Hand-writing a board over the reference dtsi lands ~34 nodes off — LED GPIOs, IR key tables,
BT/Wi-Fi GPIOs, regulator wiring, voltage binning. Generating the overrides from the blob is exact.

## Requirements

the patched `dtc` (`./build-dtc.sh`). Steps 5 and 6 also need the kernel's `dt-bindings` and
reference dtsi; `build.sh` fetches them sparsely at a pinned commit. Without them it still builds
the submission and exits 0.

| Variable                               | Default                                            |
| -------------------------------------- | -------------------------------------------------- |
| `KERNEL` / `KERNEL_URL` / `KERNEL_REV` | `upstream/.kernel`, armbian/linux-rockchip, pinned |
| `BOARD` / `STOCK` / `SOC` / `BASE`     | board dir, `stock/` dir, SoC, reference dtsi       |

`build.sh` builds `$BOARD`; a second board is another directory with its patch, built by overriding
`BOARD`, `STOCK`, `SOC` and `BASE`. Nothing in the patched `dtc` or `scripts/` is board-specific.
