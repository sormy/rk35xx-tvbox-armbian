# Device trees, for upstreaming

A board tree as a diff against that box's own factory tree. `<board>/armbian.patch` is the only file
edited by hand; `./build.sh` regenerates the rest and verifies it.

## Process

1. Carve the DTB from the eMMC dump, never off a running box — u-boot rewrites the tree it hands to
   Linux. Find it by its `d00dfeed` magic in the `boot` partition. → `stock/<board>/board.dtb`
2. Decompile: `dtcx -I dtb -O dts -P -n` (`-P` phandles → `&label`, `-n` drops `__symbols__`).
3. Edit into the Armbian tree; comment each change with the consumer that needs it. Then:
   ```sh
   cd <board> && diff -u --label board.dts --label armbian.dts board.dts armbian.dts > armbian.patch
   ```
4. Build its DTB — this is what boots. Copy `armbian.dts` and `armbian.dtb` over
   `firmware/<board>/board.dts` and `board.dtb` — **needed for overlay mode**, where that pair is
   what images ship and what `rk35xx-update` installs, and it has no other source. An upstreamed
   board gets its DTB from the kernel package instead and never reads `firmware/`.
5. `scripts/gen-overrides.py` re-expresses it as `/delete-node/` + `&label { }` over the vendor's
   reference dtsi. That output (`armbian-native.dts`) is a machine reference — correct, but with no
   reasons in it.
6. Carry it into `armbian-native-annotated.dts` **by hand**, one short comment per block saying why
   the block exists. A blob carries no reasons and a guessed one is worse than none, so a block
   whose purpose is unknown gets a plain statement of what changed, not an invented cause. When the
   patch changes, diff the two files to see what to carry over.
7. Verify both describe the same hardware, ignoring phandle values:
   ```
   VERIFIED: native tree is content-identical to the patched tree
   ```

Steps 2, 4, 5 and 7 are `./build.sh`; steps 3 and 6 are human. `build.sh` compiles the annotated
file, not the generated one, so forgetting to carry a change over fails the gate rather than
shipping quietly. Comments never reach the blob, so they cannot break it — but they can drift, and
nothing but reading catches a comment that is merely wrong.

## Files

One directory per board, named after the installed dtb — `r69-xr821/`, `h96max-zx/`. Two files are
source; the rest is generated and gitignored.

| File                           | What                                                       |
| ------------------------------ | ---------------------------------------------------------- |
| `armbian.patch`                | **source** — the grafts, against the factory tree          |
| `armbian-native-annotated.dts` | **source** — the `#include` form, commented by hand        |
| `board.dtb` / `board.dts`      | factory blob and its decompile                             |
| `armbian.dts` / `.dtb`         | patch applied                                              |
| `armbian-consts.dts`           | `dt-bindings` names instead of hex                         |
| `armbian-native.dts`           | machine-generated overrides, a reference to diff against   |
| `armbian-native.dtb`           | built from the annotated file, gated against `armbian.dtb` |

## Why a diff

The vendor ships a binary, so the factory tree is the specification and the reviewable artifact is
what we change about it. `board.dts` recompiles byte-identical to the factory blob; the explicit
`phandle` properties are what make that true and must stay.

Hand-writing a board over the reference dtsi lands ~34 nodes off — LED GPIOs, IR key tables,
BT/Wi-Fi GPIOs, regulator wiring, voltage binning. Generating the overrides from the blob is exact.

## Requirements

`dtcx` (`make -C ../dtcx`). Steps 5 and 6 also need the kernel's `dt-bindings` and reference dtsi;
`build.sh` fetches them sparsely at a pinned commit. Without them it still builds the submission and
exits 0.

| Variable                               | Default                                            |
| -------------------------------------- | -------------------------------------------------- |
| `KERNEL` / `KERNEL_URL` / `KERNEL_REV` | `upstream/.kernel`, armbian/linux-rockchip, pinned |
| `BOARD` / `STOCK` / `SOC` / `BASE`     | board dir, `stock/` dir, SoC, reference dtsi       |

`build.sh` builds `$BOARD`; a second board is another directory with its patch, built by overriding
`BOARD`, `STOCK`, `SOC` and `BASE`. Nothing in `dtcx` or `scripts/` is board-specific.
