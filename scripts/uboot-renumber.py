#!/usr/bin/env python3
"""Retarget a decompiled vendor U-Boot DTS at mainline U-Boot's bindings.

A clock reference is <&cru N>. The phandle picks the controller and survives translation untouched;
N is an index into whichever driver reads it, and the vendor and mainline enumerate the same clocks
differently — the vendor's CLK_SARADC is 257, mainline's is 195, and mainline reads 257 as
ACLK_VOP_BIU. The blob stores only the integer, so no decompiler can recover the name: the vendor
header is the dictionary that supplies it and mainline's header gives the new value.

Resets need the same treatment plus a naming rule, the vendor spelling SRST_PRESETN_SARADC where
mainline spells it SRST_P_SARADC.

Phase tags move to the bootph-* schema mainline has used since 2023; the vendor's sit on the right
nodes already.

A cell that does not map to exactly one value is reported on stderr and the run refuses to emit:
a half-retargeted tree ships vendor indices mainline reads as other clocks.
Env: VHDR, MDIR, CRU_PH, BOARD.

  Usage: uboot-renumber.py <decompiled.dts> > retargeted.dts
"""
import os, re, sys

# no SCMI_: those ids address the scmi_clk provider and can never appear in a <&cru N> cell, so
# collecting them only collides with the low CRU numbers (vendor 1-32) and blocks their retarget
CLK_PREFIX = ('CLK', 'SCLK_', 'PCLK_', 'HCLK_', 'ACLK_', 'CCLK_', 'BCLK_', 'TCLK_', 'DBCLK_',
              'MCLK_', 'DCLK_', 'XIN_')
TAGS = {'u-boot,dm-pre-reloc': 'bootph-all', 'u-boot,dm-spl': 'bootph-pre-ram'}


def _int(tok):
    # a cell after the cru token need not be an index - another reference can follow it
    try:
        return int(tok, 0)
    except ValueError:
        return None


def defines(path):
    return re.findall(r'^#define\s+([A-Z0-9_]+)\s+(0x[0-9a-fA-F]+|\d+)\s*$', open(path).read(), re.M)


def by_value(path, keep):
    out = {}
    for name, val in defines(path):
        if keep(name):
            out.setdefault(int(val, 0), []).append(name)
    return out


def by_name(path):
    return {name: int(val, 0) for name, val in defines(path)}


def reset_spelling(name):
    """SRST_PRESETN_SARADC -> SRST_P_SARADC, SRST_RESETN_CORE_CRYPTO -> SRST_CORE_CRYPTO."""
    return re.sub(r'^SRST_([A-Z])RESETN_', r'SRST_\1_', re.sub(r'^SRST_RESETN_', 'SRST_', name))


def main():
    vhdr, mdir, cru = os.environ['VHDR'], os.environ['MDIR'], os.environ['CRU_PH']
    board = os.environ.get('BOARD', '?')
    vendor_clk = by_value(vhdr, lambda n: n.startswith(CLK_PREFIX))
    vendor_rst = by_value(vhdr, lambda n: n.startswith('SRST_'))
    main_clk = by_name(os.path.join(mdir, 'clock', 'rockchip,rk3528-cru.h'))
    main_rst = by_name(os.path.join(mdir, 'reset', 'rockchip,rk3528-cru.h'))
    # -P renders a resolved reference by path; it leaves the raw value where the walk could not
    # consume the property exactly (a mixed-provider clocks= is the common case)
    if not cru:
        sys.exit('CRU_PH is empty - the cru phandle was not found, nothing would retarget')
    cru_tokens = {cru, '&{/clock-controller@ff4a0000}'}

    text = sys.stdin.read() if sys.argv[1] == '-' else open(sys.argv[1]).read()
    counts, skipped = {'clock': 0, 'reset': 0, 'tag': 0}, []

    def retarget(props, vendor, mainline, kind, spell):
        def one(match):
            cells, out, i = match.group(1).split(), [], 0
            while i < len(cells):
                if cells[i] in cru_tokens and i + 1 < len(cells) and _int(cells[i + 1]) is not None:
                    old = _int(cells[i + 1])
                    names = {spell(n) for n in vendor.get(old, [])}
                    hits = {mainline[n] for n in names if n in mainline}
                    if len(hits) == 1:
                        out += [cells[i], hex(hits.pop())]
                        counts[kind] += 1
                    else:
                        out += [cells[i], cells[i + 1]]
                        skipped.append(f"{kind} {old}: vendor {sorted(names) or 'unknown'} -> "
                                       f"{sorted(hits) if hits else 'no mainline symbol'}")
                    i += 2
                else:
                    out.append(cells[i])
                    i += 1
            return f"<{' '.join(out)}>"

        # a property holds one group per provider - clocks = <&cru A>, <&other B>; - so match to
        # the ';' and rewrite every group. Matching a single <...> retargets the first and ships
        # the rest as vendor indices.
        def prop(match):
            return match.group(1) + re.sub(r'<([^>]*)>', one, match.group(2)) + ';'
        return re.sub(rf'(\b(?:{props})\s*=\s*)([^;]*);', prop, text)

    text = retarget('clocks|assigned-clocks|assigned-clock-parents', vendor_clk, main_clk, 'clock', lambda n: n)
    text = retarget('resets', vendor_rst, main_rst, 'reset', reset_spelling)
    for old, new in TAGS.items():
        text, n = re.subn(rf'^(\s*){re.escape(old)};$', rf'\1{new};', text, flags=re.M)
        counts['tag'] += n

    print(f"  {board}: {counts['clock']} clock, {counts['reset']} reset cells retargeted, "
          f"{counts['tag']} phase tags", file=sys.stderr)
    for s in sorted(set(skipped)):
        print(f"  {board}: LEFT AS IS - {s}", file=sys.stderr)

    # fail before emitting: a partial retarget ships vendor indices mainline reads as other clocks
    # (vendor 163 is mainline PCLK_UART7 — the eMMC would be clocked against a UART). Not an
    # assert, which `python3 -O` removes.
    # any cell left at a vendor index is the hazard named above, not a warning: no board here
    # produces one, so a new skip means the headers moved and the result must not ship
    if skipped:
        sys.exit(f"{board}: {len(skipped)} cell(s) left at vendor numbering - refusing to emit")
    if not counts['clock'] or not counts['reset']:
        sys.exit(f"{board}: retarget did nothing ({counts['clock']} clock, {counts['reset']} reset)"
                 " - CRU_PH or the vendor header is wrong")
    sys.stdout.write(text)


main()
