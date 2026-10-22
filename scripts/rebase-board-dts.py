#!/usr/bin/env python3
"""Rebase a board's tree onto a kernel's reference design, proven content-identical.

firmware/<board>/board.dtb becomes overrides on the reference dtsi: /delete-node/ for what the box
lacks, &label { } for what it changes, whole nodes for what it adds. The result is compiled with
that kernel's includes and compared line for line against board.dtb, phandles translated by node
path, so it matches only if every node and every &label resolves the same. Clock, reset, power and
interrupt cells are written with their dt-bindings names where the header gives exactly one.

  Usage: rebase-board-dts.py <board> [--rev <commit>] [--reference <dtsi>]
  -> build/rebase/<board>/native.dts
"""

from __future__ import annotations

import argparse
import difflib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

REPO = Path(__file__).resolve().parent.parent
DTC = REPO / "build/bin/dtc"
KERNEL_URL = "https://github.com/armbian/linux-rockchip.git"
KERNEL_REV = "5280f9b4336199c4025c8eed894d2b4e2268dcc6"
DTS_DIR = "arch/arm64/boot/dts/rockchip"
REFERENCE = "rk3528-evb1-ddr4-v10.dtsi"
SOC = "rk3528"
SOC_LINUX = f"{SOC}-linux.dtsi"
LABELS = re.compile(r"^([\w-]+:\s*)+")
CELLS_PROPERTY = re.compile(r"^\s*([\w,.+#-]+)\s*=\s*(<[^>]*>)\s*;\s*$")
PHANDLE = "phandle = <"
DEFINE = re.compile(r"^#define\s+(\w+)\s+(\d+)\s*$", re.M)
PROVIDER_CELLS = re.compile(
    r"\b(clocks|assigned-clocks|assigned-clock-parents|resets|power-domains) = <([^>]*)>;"
)
INTERRUPTS = re.compile(r"\binterrupts = <([^>]*)>;")
GIC_TYPES = {0: "GIC_SPI", 1: "GIC_PPI"}
IRQ_TYPES = {
    1: "IRQ_TYPE_EDGE_RISING",
    2: "IRQ_TYPE_EDGE_FALLING",
    4: "IRQ_TYPE_LEVEL_HIGH",
    8: "IRQ_TYPE_LEVEL_LOW",
}
# provider label -> (header, the names it can mean): 0x16 is both CLK_UART1_SRC and SCMI_CLK_GPU
PROVIDERS: dict[str, tuple[str, Callable[[str], bool]]] = {
    "cru": (f"clock/{SOC}-cru.h", lambda name: not name.startswith("SCMI_")),
    "scmi_clk": (f"clock/{SOC}-cru.h", lambda name: name.startswith("SCMI_")),
    "power": (f"power/{SOC}-power.h", lambda name: True),
}


@dataclass
class Node:
    name: str
    labels: list[str]
    props: dict[str, str | None] = field(default_factory=dict)


def run(cmd: list[str], stdin: bytes = b"") -> bytes:
    done = subprocess.run(cmd, input=stdin, capture_output=True)
    if done.returncode:
        sys.exit(f"{cmd[0]} failed:\n{done.stderr.decode()}")
    return done.stdout


def fetch_kernel(rev: str) -> Path:
    tree = REPO / "build/kernel-dts" / rev
    if not (tree / DTS_DIR).is_dir():
        git = ["git", "-C", str(tree)]
        run(["git", "init", "-q", str(tree)])
        run([*git, "fetch", "-q", "--depth", "1", "--filter=blob:none", KERNEL_URL, rev])
        run([*git, "sparse-checkout", "set", "include/dt-bindings", DTS_DIR])
        run([*git, "checkout", "-q", "FETCH_HEAD"])
    return tree


def compile_dts(source: str, kernel: Path) -> bytes:
    cpp = ["cc", "-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp"]
    includes = ["-I", str(kernel / "include"), "-I", str(kernel / DTS_DIR)]
    flat = run([*cpp, *includes, "-"], source.encode())
    return run([str(DTC), "-@", "-q", "-I", "dts", "-O", "dtb"], flat)


def decompile(dtb: bytes, *flags: str) -> str:
    return run([str(DTC), "-q", "-I", "dtb", "-O", "dts", "-P", "-n", *flags], dtb).decode()


def walk(dts: str) -> Iterator[tuple[str, str]]:
    """(line, path of the node it sits in) for every line of a decompiled tree."""
    stack: list[str] = []
    for line in dts.splitlines():
        text = line.strip()
        depth = len(line) - len(line.lstrip("\t"))
        if text.endswith("{"):
            stack = stack[:depth] + [LABELS.sub("", text[:-1].strip())]
        elif text == "};":
            stack = stack[:depth]
        yield line, "/" + "/".join(stack[1:])


def parent(path: str) -> str:
    return path.rsplit("/", 1)[0] or "/"


def parse(dts: str) -> dict[str, Node]:
    nodes: dict[str, Node] = {}
    for line, path in walk(dts):
        text = line.strip()
        if text.endswith("{"):
            head = text[:-1].strip()
            prefix = LABELS.match(head)
            labels = prefix.group(0) if prefix else ""
            nodes[path] = Node(head[len(labels) :], re.findall(r"[\w-]+", labels))
        elif text.endswith(";") and text != "};" and path in nodes:
            key, eq, value = text[:-1].partition("=")
            if key.strip() != "phandle":
                nodes[path].props[key.strip()] = value.strip() if eq else None
    return nodes


def reference(path: str, node: Node) -> str:
    return f"&{node.labels[0]}" if node.labels else f"&{{{path}}}"


def properties(props: dict[str, str | None], indent: str) -> list[str]:
    return [f"{indent}{k};" if v is None else f"{indent}{k} = {v};" for k, v in props.items()]


def subtree(path: str, nodes: dict[str, Node], indent: str) -> list[str]:
    node = nodes[path]
    lines = [indent + "".join(f"{l}: " for l in node.labels) + node.name + " {"]
    lines += properties(node.props, indent + "\t")
    for child in (p for p in nodes if p != path and parent(p) == path):
        lines += subtree(child, nodes, indent + "\t")
    return lines + [indent + "};"]


def overrides(base: dict[str, Node], target: dict[str, Node]) -> str:
    gone = set(base) - set(target)
    deleted = [
        f"/delete-node/ {reference(p, base[p])};" for p in sorted(gone) if parent(p) not in gone
    ]
    changed: list[str] = []
    for path in sorted(set(base) & set(target)):
        was, now = base[path].props, target[path].props
        dropped = [f"\t/delete-property/ {k};" for k in sorted(set(was) - set(now))]
        differs = {k: v for k, v in now.items() if k not in was or was[k] != v}
        node = reference(path, base[path])
        # dtc takes one label per &reference
        changed += [
            f"{l}: {node} {{ }};" for l in target[path].labels if l not in base[path].labels
        ]
        if dropped or differs:
            changed.append("\n".join([f"{node} {{", *dropped, *properties(differs, "\t"), "};"]))
    added = [
        "\n".join([f"{reference(parent(p), base[parent(p)])} {{", *subtree(p, target, "\t"), "};"])
        for p in sorted(set(target) - set(base))
        if parent(p) in base
    ]
    return "\n\n".join(["\n".join(deleted), *changed, *added]) + "\n"


class Bindings:
    """Names a tree's numbers from the kernel's dt-bindings headers, by the provider each cell is
    for. A name expands to the number it replaces, so the tree compiles the same."""

    def __init__(self, kernel: Path) -> None:
        self.used: set[str] = set()
        self.names: dict[str, tuple[str, dict[int, list[str]]]] = {}
        for provider, (header, means) in PROVIDERS.items():
            path = kernel / "include/dt-bindings" / header
            table: dict[int, list[str]] = {}
            for name, value in DEFINE.findall(path.read_text() if path.is_file() else ""):
                if means(name):
                    table.setdefault(int(value), []).append(name)
            self.names[provider] = (header, table)

    def name(self, provider: str, token: str) -> str:
        header, table = self.names.get(provider, ("", {}))
        names = table.get(int(token, 16), []) if token.startswith("0x") else []
        if len(names) != 1:
            return token
        self.used.add(header)
        return names[0]

    def provider_cells(self, match: re.Match[str]) -> str:
        provider, tokens = "", []
        for token in match.group(2).split():
            provider = token[1:] if token.startswith("&") else provider
            tokens.append(token if token.startswith("&") else self.name(provider, token))
        return f"{match.group(1)} = <{' '.join(tokens)}>;"

    def interrupts(self, match: re.Match[str]) -> str:
        """GIC three-cell form only: <0x00 0x58 0x04> -> <GIC_SPI 88 IRQ_TYPE_LEVEL_HIGH>"""
        tokens = match.group(1).split()
        if not tokens or len(tokens) % 3 or not all(t.startswith("0x") for t in tokens):
            return match.group(0)
        values = [int(t, 16) for t in tokens]
        triples = [values[i : i + 3] for i in range(0, len(values), 3)]
        if not all(t[0] in GIC_TYPES and t[2] in IRQ_TYPES for t in triples):
            return match.group(0)
        self.used |= {"interrupt-controller/arm-gic.h", "interrupt-controller/irq.h"}
        cells = " ".join(f"{GIC_TYPES[a]} {b} {IRQ_TYPES[c]}" for a, b, c in triples)
        return f"interrupts = <{cells}>;"

    def named(self, dts: str) -> str:
        """dts with its numbers named, after the includes that define them"""
        dts = INTERRUPTS.sub(self.interrupts, PROVIDER_CELLS.sub(self.provider_cells, dts))
        return "".join(f"#include <dt-bindings/{h}>\n" for h in sorted(self.used)) + "\n" + dts


def phandles(dts: str) -> dict[str, str]:
    return {path: line.split("<")[1].split(">")[0] for line, path in walk(dts) if PHANDLE in line}


def numeric_references(trees: list[str]) -> list[str]:
    """A property written <&label> anywhere must never appear as bare cells: that number names a
    different node in each tree, and no diff can see it."""
    cells = [m.groups() for dts in trees for m in map(CELLS_PROPERTY.match, dts.splitlines()) if m]
    symbolic = {name for name, value in cells if "&" in value}
    return [f"{name} = {value}" for name, value in cells if name in symbolic and "&" not in value]


def remap_phandles(reference_dts: str, target_dts: str) -> str:
    """target_dts with each node's phandle replaced by the one reference_dts gives that node."""
    wanted = phandles(reference_dts)
    return "\n".join(
        (
            re.sub(r"<0x[0-9a-f]+>", f"<{wanted[path]}>", line)
            if PHANDLE in line and path in wanted
            else line
        )
        for line, path in walk(target_dts)
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("board")
    parser.add_argument("--rev", default=KERNEL_REV, help="kernel commit to rebase onto")
    parser.add_argument("--reference", default=REFERENCE, help="the design the board derives from")
    args = parser.parse_args()
    if not DTC.is_file():
        sys.exit("Need the patched dtc. Run: ./build.sh tool dtc")

    kernel = fetch_kernel(args.rev)
    includes = f'/dts-v1/;\n#include "{args.reference}"\n#include "{SOC_LINUX}"\n'
    board_dtb = (REPO / "firmware" / args.board / "board.dtb").read_bytes()
    base = parse(decompile(compile_dts(includes, kernel)))
    board = overrides(base, parse(decompile(board_dtb)))
    native = includes + Bindings(kernel).named(board)
    out = REPO / "build/rebase" / args.board / "native.dts"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(native)

    want = decompile(board_dtb, "-s")
    got = decompile(compile_dts(native, kernel), "-s")
    numeric = numeric_references([want, got])
    if numeric:
        sys.exit("left numeric; teach dtc the property:\n" + "\n".join(numeric))
    diff = difflib.unified_diff(
        want.splitlines(),
        remap_phandles(want, got).splitlines(),
        "board.dtb",
        "native.dts",
        lineterm="",
    )
    mismatch = "\n".join(diff)
    if mismatch:
        sys.exit(f"{out.relative_to(REPO)} differs from board.dtb:\n{mismatch}")
    print(f"-> {out.relative_to(REPO)}, content-identical to firmware/{args.board}/board.dtb")


if __name__ == "__main__":
    main()
