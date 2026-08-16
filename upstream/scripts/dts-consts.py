#!/usr/bin/env python3
"""Replace magic numbers in a decompiled DTS with their dt-bindings names.

A decompiled tree has only numbers: the macro names were expanded by cpp long before the blob
existed. They are recoverable by looking the values up in the kernel's dt-bindings headers, which
is what this does -- a lookup against the authoritative header, never a guess at meaning. The
emitted value is unchanged, so the tree still compiles to the same blob (via cpp, then dtc).

Which header applies is decided by the *provider* the phandle points at, not by the value: 0x16 is
both CLK_UART1_SRC and SCMI_CLK_GPU, and only "&cru" vs "&scmi_clk" says which. Where that is
ambiguous the number is left alone.

  Usage: dts-consts.py <in.dts> <kernel>/include/dt-bindings <soc> > out.dts
"""
import re
import sys

# provider label -> (header, name filter). The filter picks between names sharing a value.
PROVIDERS = {
    "cru": ("clock/{soc}-cru.h", lambda n: not n.startswith("SCMI_")),
    "scmi_clk": ("clock/{soc}-cru.h", lambda n: n.startswith("SCMI_")),
    "power": ("power/{soc}-power.h", lambda n: True),
}
CELL_PROPS = ("clocks", "assigned-clocks", "assigned-clock-parents", "resets", "power-domains")
IRQ_TYPES = {1: "IRQ_TYPE_EDGE_RISING", 2: "IRQ_TYPE_EDGE_FALLING",
             4: "IRQ_TYPE_LEVEL_HIGH", 8: "IRQ_TYPE_LEVEL_LOW"}
GIC_TYPES = {0: "GIC_SPI", 1: "GIC_PPI"}


def load(path):
    """value -> [names] from a dt-bindings header."""
    out = {}
    try:
        text = open(path).read()
    except OSError:
        return out
    for name, val in re.findall(r"^#define\s+(\w+)\s+(\d+)\s*$", text, re.M):
        out.setdefault(int(val), []).append(name)
    return out


def main():
    src, bindings, soc = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
    maps = {p: (h.format(soc=soc), load(f"{bindings}/{h.format(soc=soc)}"), f)
            for p, (h, f) in PROVIDERS.items()}
    used = set()

    def name_for(provider, value):
        header, table, keep = maps.get(provider, (None, {}, None))
        names = [n for n in table.get(value, []) if keep(n)]
        if len(names) != 1:
            return None                       # unknown or ambiguous: leave the number
        used.add(header)
        return names[0]

    def cells(match):
        """<&cru 0x113 &cru 0x10e> -> <&cru ACLK_GPU_MALI &cru PCLK_GPU_ROOT>"""
        provider, out = None, []
        for tok in match.group(2).split():
            if tok.startswith("&"):
                provider, _ = tok[1:], out.append(tok)
                continue
            n = name_for(provider, int(tok, 16)) if provider and tok.startswith("0x") else None
            out.append(n or tok)
        return f"{match.group(1)} = <{' '.join(out)}>;"

    def irqs(match):
        """<0x00 0x58 0x04> -> <GIC_SPI 88 IRQ_TYPE_LEVEL_HIGH>, GIC three-cell form only"""
        tok = match.group(1).split()
        if len(tok) % 3 or not all(t.startswith("0x") for t in tok):
            return match.group(0)
        v = [int(t, 16) for t in tok]
        if not all(v[i] in GIC_TYPES and v[i + 2] in IRQ_TYPES for i in range(0, len(v), 3)):
            return match.group(0)
        used.add("interrupt-controller/arm-gic.h")
        used.add("interrupt-controller/irq.h")
        out = [f"{GIC_TYPES[v[i]]} {v[i + 1]} {IRQ_TYPES[v[i + 2]]}" for i in range(0, len(v), 3)]
        return "interrupts = <" + " ".join(out) + ">;"

    text = open(src).read()
    text = re.sub(r"\b(%s) = <([^>]*)>;" % "|".join(CELL_PROPS), cells, text)
    text = re.sub(r"\binterrupts = <([^>]*)>;", irqs, text)
    includes = "".join(f"#include <dt-bindings/{h}>\n" for h in sorted(used))
    sys.stdout.write(text.replace("/dts-v1/;\n", "/dts-v1/;\n" + includes, 1))


main()
