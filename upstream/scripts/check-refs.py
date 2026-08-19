#!/usr/bin/env python3
"""Fail if any phandle reference survived decompilation as a bare number.

A number that means a node is only valid for the allocation it was dumped from: copy it into a
tree that numbers its nodes differently and it silently points somewhere else. the patched dtc converts the
properties it knows to `&label`; one it does not know stays numeric and looks like ordinary data.

The tell needs no hand-maintained list. A property that holds a phandle is written `<&label>`
somewhere in these trees, so any name seen symbolically must never also appear as a bare cell
list. Names that are only ever numeric (`reg`, `interrupts`, `fifo-depth`) are never considered,
which is what keeps a small integer colliding with a phandle from reading as a reference.

  Usage: check-refs.py <decompiled.dts>...
"""
import re
import sys

PROP = re.compile(r"^\s*([\w,.+#-]+)\s*=\s*(<[^>]*>)\s*;\s*$")


def props(path):
    for line in open(path):
        m = PROP.match(line)
        if m:
            yield m.group(1), m.group(2)


def phandles(path):
    out, stack = {}, []
    for raw in open(path):
        line, text = raw.rstrip(), raw.strip()
        depth = len(line) - len(line.lstrip("\t"))
        if text.endswith("{"):
            stack = stack[:depth] + [re.sub(r"^([\w-]+:\s*)+", "", text[:-1].strip())]
        elif text == "};":
            stack = stack[:depth]
        elif text.startswith("phandle = <"):
            out[int(text.split("<")[1].split(">")[0], 0)] = "/" + "/".join(stack[1:])
    return out


def main():
    paths = sys.argv[1:]
    symbolic = {name for p in paths for name, val in props(p) if "&" in val}

    bad = 0
    for path in paths:
        targets = phandles(path)
        for name, val in props(path):
            if name not in symbolic or "&" in val:
                continue
            cells = [int(c, 0) for c in re.findall(r"0x[0-9a-f]+|\b\d+\b", val)]
            hit = next((targets[c] for c in cells if c in targets), None)
            print(f"{path}: {name} = {val} left numeric"
                  f"{' -> ' + hit if hit else ''}", file=sys.stderr)
            bad += 1

    if bad:
        print(f"{bad} unresolved reference(s): teach dtc the property, then rebuild",
              file=sys.stderr)
    return 1 if bad else 0


sys.exit(main())
