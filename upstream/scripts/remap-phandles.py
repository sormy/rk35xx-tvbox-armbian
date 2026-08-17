#!/usr/bin/env python3
"""Rewrite a tree's phandle values to the ones a reference tree gives the same nodes.

A phandle's value is allocated per compile, so two trees describing one board disagree on it and
nothing else. Translating by node path — rather than dropping the property — leaves every line
comparable: if the remapped tree then matches the reference, every node carries a phandle, it is
the same one, and every `&label` beside it names the same node.

A node whose phandle has no counterpart keeps its own value and is reported, so the diff shows it.

  Usage: remap-phandles.py <reference.dts> <target.dts> > remapped.dts
"""
import re
import sys

LABELS = re.compile(r"^([\w-]+:\s*)+")


def walk(path):
    """(line, node path) for every line, node path being the node the line sits in."""
    stack = []
    for raw in open(path):
        line, text = raw.rstrip("\n"), raw.strip()
        depth = len(line) - len(line.lstrip("\t"))
        if text.endswith("{"):
            stack = stack[:depth] + [LABELS.sub("", text[:-1].strip())]
        elif text == "};":
            stack = stack[:depth]
        yield line, "/" + "/".join(stack[1:])


def phandles(path):
    return {node: line.strip().split("<")[1].split(">")[0]
            for line, node in walk(path) if line.strip().startswith("phandle = <")}


def main():
    reference, target = sys.argv[1], sys.argv[2]
    ref = phandles(reference)
    unmapped = []

    for line, node in walk(target):
        if line.strip().startswith("phandle = <"):
            if node in ref:
                line = re.sub(r"<0x[0-9a-f]+>", f"<{ref[node]}>", line)
            else:
                unmapped.append(node)
        print(line)

    for node in unmapped:
        print(f"no phandle for {node} in {reference}", file=sys.stderr)


main()
