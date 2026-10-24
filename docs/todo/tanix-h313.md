# Tanix H313: the first Allwinner board, and a test of the bring-up docs

A Tanix box on Allwinner's H313, brought up by an AI agent from this repo's docs alone. Two goals,
equal weight: a working board, and proof that the docs carry a new family and a new board without
the maintainer filling gaps. Board key `tanix-h313`, the product's name; its SoC is Allwinner's H313
as well.

## The test

The agent gets the box on serial and USB, `AGENTS.md`, and the docs it indexes, nothing else. Every
point where it stalls, guesses, or asks is a doc defect: fixed in that doc, logged in this board's
worklog. Done when a second agent could repeat the port from the fixed docs.

| Instruction under test | Proves                                                 |
| ---------------------- | ------------------------------------------------------ |
| the board bring-up     | evidence, backup, tree, board data, from a factory box |
| a new family's steps   | kernel, U-Boot, image layout for a SoC the repo lacks  |
| the criteria of done   | each line ✅ with its command's output                 |

A new family has no steps written yet; writing them, from this port, is part of the work.

## Steps

1. **Identity and backup.** The PCB's silkscreen, the full eMMC to `backup/<board>-stock.img.xz`,
   Android's own evidence to `stock/<board>/`.
2. **Allwinner evidence.** `boot0` and its DRAM parameters; the vendor boot package's hardware
   description (pins, PMIC, regulators); the sectors holding the unit's serial and MACs.
3. **The family.** `kernel/sunxi64.conf` on kernel.org longterm; mainline U-Boot with TF-A and the
   extracted DRAM values; a `sunxi` layout in `image/build.sh`. ❓ secure boot fused off, so the
   boot ROM runs an unsigned loader: first proven from SD, the eMMC untouched.
4. **The board.** Tree, `board.conf`, `preserve-sectors`; the Wi-Fi chip as a `chips/<chip>/` if no
   mainline driver covers it.
5. **Validation**, every criterion of done, then `tvb-install` to the eMMC with the identity sectors
   kept.

## Expected trouble, from linux-sunxi practice

- ❓ HDMI and video decode on the H616 generation: newer in mainline than the rest.
- ❓ Wi-Fi: often the Unisoc UWE5622 or Allwinner's XR819, neither in mainline.
- A wrong DRAM or PMIC value fails silently or damages; both come from the factory's own data.
