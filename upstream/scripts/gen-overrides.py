#!/usr/bin/env python3
"""Generate the board overrides that turn an included reference tree into this box's tree.

Both inputs are decompiled with dtcx (-P -n), so references are already &labels and survive the
copy. Emits, for each difference: a node override for changed properties, the whole node for one
the base lacks, /delete-node/ for one the base has and the box does not.

  Usage: gen-overrides.py <base.dts> <target.dts> > overrides.dtsi
"""
import re
import sys


def parse(path):
    """path -> (props, label, children order). Nodes keyed by full path."""
    nodes, stack = {}, []
    for raw in open(path):
        line = raw.rstrip()
        text = line.strip()
        depth = len(line) - len(line.lstrip("\t"))
        if text.endswith("{"):
            head = text[:-1].strip()
            label = None
            m = re.match(r"^([\w-]+):\s*(.*)$", head)
            if m:
                label, head = m.group(1), m.group(2).strip()
            stack = stack[:depth] + [head]
            nodes["/".join(stack)] = {"label": label, "props": {}, "name": head}
        elif text == "};":
            stack = stack[:depth]
        elif "=" in text and text.endswith(";") and stack:
            k, v = text.split("=", 1)
            if k.strip() == "phandle":
                continue
            nodes["/".join(stack)]["props"][k.strip()] = v.strip().rstrip(";")
        elif text.endswith(";") and text[:-1].strip() and stack:
            nodes["/".join(stack)]["props"][text[:-1].strip()] = None   # boolean property
    return nodes


def dtpath(path):
    """internal key ('/', '//aliases') -> device tree path ('/', '/aliases')"""
    return "/" if path == "/" else path[1:]


def addr(path, node):
    """How to reach a node from an override: its label if it has one, else its path."""
    return f"&{node['label']}" if node["label"] else "&{%s}" % dtpath(path)


def emit_node(path, nodes, indent="\t"):
    """A whole node, with its subtree, for something the base does not have."""
    n = nodes[path]
    out = [f"{indent}{n['label'] + ': ' if n['label'] else ''}{n['name']} {{"]
    for k, v in n["props"].items():
        out.append(f"{indent}\t{k};" if v is None else f"{indent}\t{k} = {v};")
    for child in [p for p in nodes if p.startswith(path + "/") and "/" not in p[len(path) + 1:]]:
        out += emit_node(child, nodes, indent + "\t")
    out.append(indent + "};")
    return out


def main():
    base, target = parse(sys.argv[1]), parse(sys.argv[2])
    out = []

    for path in sorted(set(base) - set(target)):
        if any(p in base and p in set(base) - set(target) for p in [path.rsplit("/", 1)[0]]):
            continue                                    # parent already deleted
        out.append(f"/delete-node/ {addr(path, base[path])};")
    if out:
        out.insert(0, "/* nodes the reference board has and this box does not */")

    changed = []
    for path in sorted(set(base) & set(target)):
        b, t = base[path]["props"], target[path]["props"]
        diff = {k: t[k] for k in t if k not in b or b[k] != t[k]}
        gone = [k for k in b if k not in t]
        if not diff and not gone:
            continue
        body = [f"\t/delete-property/ {k};" for k in sorted(gone)]
        body += [f"\t{k};" if v is None else f"\t{k} = {v};" for k, v in diff.items()]
        changed.append(f"{addr(path, base[path])} {{\n" + "\n".join(body) + "\n};")

    added = [p for p in sorted(set(target) - set(base))
             if p.rsplit("/", 1)[0] in base or "/" not in p]
    new = []
    for path in added:
        parent = path.rsplit("/", 1)[0]
        if parent in base:
            new.append(f"{addr(parent, base[parent])} {{\n" +
                       "\n".join(emit_node(path, target)) + "\n};")

    print("\n".join(out))
    print("\n" + "\n\n".join(changed))
    print("\n" + "\n\n".join(new))
    print(f"\n/* {len(out)} deletes, {len(changed)} node overrides, {len(new)} added nodes */",
          file=sys.stderr)


main()
