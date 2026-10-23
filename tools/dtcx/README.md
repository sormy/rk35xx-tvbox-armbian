# dtcx — a blob decompiled into the source its vendor wrote

`dtc -P` turns a device tree blob back into source, but only into numbers: `<&cru 0x101>`,
`<0x00 0x58 0x04>`, `<0x1b7740>`. The vendor's source named most of them from dt-bindings headers.
`dtcx` writes them back: `<&cru CLK_SARADC>`, `<GIC_SPI 88 IRQ_TYPE_LEVEL_HIGH>`, `<1800000>`.

A tree written that way moves between binding versions, vendor to mainline, by a patch that swaps
the `#include`s and the few names that differ; the numbers follow the headers it is compiled
against.

On the host, after `./build.sh tool dtc`; the first run fetches a base's headers:

```sh
tools/dtcx/dtcx.py -n <base> factory_board.dtb > factory_board.dts   # a kernel tree, symbols dropped
tools/dtcx/dtcx.py --strict <base> factory_uboot.dtb > factory_uboot.dts
tools/dtcx/dtcx.py --render <base> board.dts > board.dts.new           # a hand-edited tree, no proof
tools/dtcx/dtcx.py --include <base>                                    # its include root, for cpp
```

## The proof

A tree is written only when, compiled against the base's headers and decompiled again, it reads
exactly as the blob's own decompile. Whatever the rules name, the bytes cannot move. `--strict` also
refuses a provider cell left without a single name.

## A base

`bases/<kind>-<soc>-<vendor|mainline>-<version>.conf`, so each kind sorts together:
`kernel-gxl-mainline-6.18`, `kernel-gxl-vendor-4.9`, `kernel-rk3528-vendor-6.1`,
`uboot-rk3528-mainline-2026.10`, `uboot-rk3528-vendor-2017.09`. A board names two per tree in
`board.conf`: `_SOURCE`, the one its factory blob was built from, and `_TARGET`, the one its patched
tree compiles against.

| Key       | Holds                                                                                       |
| --------- | ------------------------------------------------------------------------------------------- |
| `source`  | the line written into the tree: repository, commit, include directory                       |
| `url`     | where the headers are fetched from, once, into `build/dtcx/<name>/`                         |
| `header`  | a dt-bindings header, one a line                                                            |
| `render`  | the renderers to run                                                                        |
| `cells`   | `<provider node> <properties> <name prefixes>`: cells after a reference; a `.h` limits them |
| `decimal` | the vendor's own quantities; `<node pattern>:<property>` where a name is ambiguous          |
| `gpio`    | the vendor's own gpio properties, which dtc cannot know hold a reference                    |
| `ref`     | the vendor's own properties holding bare references, as patterns                            |
| `rules`   | another base, whose `decimal`, `gpio` and `ref` a tree moved from it still needs            |

| Renderer        | Writes                                                              |
| --------------- | ------------------------------------------------------------------- |
| `cells`         | provider cells: clocks, resets, SCMI, power domains                 |
| `gic`           | `GIC_SPI`/`GIC_PPI`, `IRQ_TYPE_…`, the CPU mask; only under the GIC |
| `gpio-flags`    | `GPIO_ACTIVE_HIGH`, `GPIO_ACTIVE_LOW`, `GPIO_OPEN_DRAIN`            |
| `rockchip-pins` | `<bank RK_PB4 func &conf>`, `RK_FUNC_GPIO`                          |
| `input-codes`   | `KEY_…`, `BTN_…`                                                    |
| `thermal`       | `THERMAL_NO_LIMIT`                                                  |
| `opp-hz`        | `/bits/ 64 <1200000000>`                                            |

Every base also gets decimal for the devicetree schema's unit suffixes (`-hz`, `-microvolt`, `-us`,
…) but `opp-hz`, `#*-cells`, `clock-frequency`, the standard binding names `dtcx.py` lists in
`DECIMAL`, and the indices after a reference in `DECIMAL_ARGS`: clocks, resets, dmas and the like.
