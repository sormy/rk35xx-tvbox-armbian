# dtc — patches to round-trip a vendor DTB

Vanilla `dtc` v1.8.1 plus five patches, built by `../../build-dtc.sh` into `tools/dtc/`. Decompiling
a blob normally gives raw numbers; this gives references:

```
dtc  :  clocks = <0x02 0xaf>;
dtc  :  clocks = <&cru 0xaf>;          # -P
```

```sh
./build-dtc.sh          # fetch, patch, build -> tools/dtc/dtc, then gate
./build-dtc.sh --test   # re-run the gate on firmware/*/board.dtb
```

| Flag | Does                                                                  |
| ---- | --------------------------------------------------------------------- |
| `-P` | phandle values -> `&label` (or `&{/path}` if the blob has no symbols) |
| `-n` | drop the generated `__symbols__` node; `-@` rebuilds it identically   |
| `-s` | also sorts a node's labels, so `-P -s` output is a fixed point        |

## How

Everything needed is in the blob: `__symbols__` gives label names, `#<specifier>-cells` on each
target gives the group width. The patch adds the `REF_PHANDLE` markers dtc's writer already knows
how to print, for the known phandle-bearing properties — `clocks`, `*-gpios`, `pinctrl-N`,
`*-supply`, `resets`, `power-domains`, `rockchip,pins` and friends.

A property is marked **only if the walk consumes its value exactly**; anything that does not line up
(`interrupt-map`, a target missing its `#*-cells`) stays numeric. Which properties hold phandles is
binding knowledge and must be declared — values alone cannot tell you, because phandles are small
integers and would match `bus-width = <4>`.

**The table is wrong in both directions, and both directions are silent.** A missing name leaves a
reference as a number, which stays valid only for the allocation it was dumped from;
`snps,mtl-rx-config` sat that way and re-pointed at the PHY when the tree was rebuilt. A name that
does not hold a phandle gets one invented: `rockchip,taskqueue-node = <2>` is an MPP queue
**index**, and reading it as a phandle printed `&cru`. Neither shows up in a round trip — the value
recompiles to the same number in the same tree — so a new name is checked against the vendor dtsi,
not against `make test`.

## The guarantee

Explicit `phandle = <N>;` properties are preserved, so **the output recompiles byte-identical**,
with or without `__symbols__` in the source. `make test` enforces it, so a cell-arithmetic mistake
cannot reach a shipped tree. That is what keeps a labelled tree diffable against the factory blob.

Do not ship a sorted tree — `-s` reorders the blob and breaks that. It is for comparing two trees.

## Upstream

None of this is in dtc (checked against master, 2026-08); `add_phandle_marker()` exists but is only
wired to overlay `__local_fixups__`, which a board DTB has none of. Each patch here is formatted to
send. 0003 is a plain round-trip bug — `add_label()` prepends, so a blob decompiled and recompiled
with `-@` comes back with its labels reversed — and stands alone.
