#!/usr/bin/env python3
"""Decompile a device tree blob into the source its vendor wrote: named constants, decimal
quantities.

A blob holds only numbers. Its source named most of them from dt-bindings headers, and a base
file (bases/<name>.conf) says which headers that source used and which cells take their names.
A cell is named only where its number has exactly one name; everything else stays a number.
The tree is written only when, compiled against those headers and decompiled again, it reads
exactly as the blob's own decompile.

  Usage: dtcx.py [-n] [--strict] <base> <blob.dtb> > tree.dts
         dtcx.py --render <base> <tree.dts> > tree.dts.new   (no round trip: for converting by hand)
         dtcx.py --include <base>                        (the base's include root, fetched)
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from fnmatch import fnmatch
from functools import cached_property
from http import HTTPStatus
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DTC = str(REPO / "build/bin/dtc")
CACHE = REPO / "build/dtcx"

# binding properties whose cells are quantities, beyond the unit suffixes dtc itself knows
DECIMAL = (
    "opp-microvolt-*",
    "opp-microamp-*",
    "max-frequency",
    "spi-max-frequency",
    "bus-width",
    "fifo-depth",
    "reg-shift",
    "reg-io-width",
    "spi-tx-bus-width",
    "spi-rx-bus-width",
    "assigned-clock-rates",
    "drive-strength",
    "contribution",
    "polling-delay",
    "polling-delay-passive",
    "sustainable-power",
    "dynamic-power-coefficient",
    "simple-audio-card,mclk-fs",
    "linux,code",
    "bits",
    "snps,blen",
    "snps,wr_osr_lmt",
    "snps,rd_osr_lmt",
    "snps,tx-queues-to-use",
    "snps,rx-queues-to-use",
    "poll-interval",
    "mclk-fs",
    "max-speed",
    "dai-tdm-slot-num",
    "dai-tdm-slot-width",
    "states",
    "*/trips/*:temperature",
    "*/trips/*:hysteresis",
)
# the unit suffixes the devicetree schema defines (dtschema's property-units)
UNIT_SUFFIXES = (
    "-bits",
    "-kBps",
    "-percent",
    "-bp",
    "-mhz",
    "-hz",
    "-sec",
    "-ms",
    "-us",
    "-ns",
    "-ps",
    "-mm",
    "-microamp",
    "-microamp-hours",
    "-nanoamp",
    "-ohms",
    "-micro-ohms",
    "-microohms",
    "-kohms",
    "-microwatt",
    "-milliwatt",
    "-microwatt-hours",
    "-microvolt",
    "-picofarads",
    "-femtofarads",
    "-celsius",
    "-millicelsius",
    "-kpascal",
    "-pascal",
    "-degrees",
)
# indices that follow a reference: dma request lines, gpio ranges, adc channels
DECIMAL_ARGS = (
    "assigned-clocks",
    "assigned-clock-parents",
    "dmas",
    "gpio-ranges",
    "io-channels",
    "clocks",
    "resets",
    "phys",
    "pwms",
    "thermal-sensors",
    "cooling-device",
    "mboxes",
    "iommus",
    "power-domains",
    "sound-dai",
)
GPIO_FLAGS = {0: "GPIO_ACTIVE_HIGH", 1: "GPIO_ACTIVE_LOW", 6: "GPIO_OPEN_DRAIN"}
GIC_TYPES = {0: "GIC_SPI", 1: "GIC_PPI"}
IRQ_TYPES = {
    1: "IRQ_TYPE_EDGE_RISING",
    2: "IRQ_TYPE_EDGE_FALLING",
    4: "IRQ_TYPE_LEVEL_HIGH",
    8: "IRQ_TYPE_LEVEL_LOW",
}
# an object-like macro; a function-like one has its ( straight after the name
PROPERTY_START = re.compile(r"^\s*[#\w,.+?-]+ = ")
STATEMENT_END = re.compile(r";\s*(/\*.*\*/)?\s*$")
DEFINE = re.compile(r"^#define\s+([A-Za-z_]\w*)\s+\S", re.M)
# C's integer operators; / and % are left out, since Python's differ from C's on negatives
ARITHMETIC = (
    ast.Expression,
    ast.BinOp,
    ast.UnaryOp,
    ast.Constant,
    ast.Add,
    ast.Sub,
    ast.Mult,
    ast.LShift,
    ast.RShift,
    ast.BitOr,
    ast.BitAnd,
    ast.BitXor,
    ast.Invert,
    ast.USub,
    ast.UAdd,
)
CELL_MASK = 0xFFFFFFFF
FETCH_ATTEMPTS = 5
FETCH_BACKOFF_S = 10
PROPERTY = re.compile(r"^(\s*)([#\w,.+?-]+) = (.*);(.*)$")
FLAG = re.compile(r"^(\s*)([#\w,.+?-]+);$")
GROUP = re.compile(r"<([^<>]*)>")
GROUPS = re.compile(r"<[^<>]*>(?:, <[^<>]*>)+")
WIDTH = 100  # a line, tabs at 8
# a cell: a bracketed expression whole, (GIC_CPU_MASK_SIMPLE(4) | IRQ_TYPE_LEVEL_LOW), or a word
TOKEN = re.compile(r"\((?:[^()]|\([^()]*\))*\)|\S+")


@dataclass
class Cells:
    """Cells following a reference to node `provider` in `props`, named from `prefixes`; a prefix
    ending in .h is a header, and limits the names to the ones it declares."""

    provider: str
    props: list[str]
    prefixes: tuple[str, ...]


@dataclass
class Base:
    name: str
    source: str
    url: str
    headers: list[str] = field(default_factory=list)
    renderers: set[str] = field(default_factory=set)
    cells: list[Cells] = field(default_factory=list)
    decimal: list[str] = field(default_factory=list)
    gpio: set[str] = field(default_factory=set)
    refs: list[str] = field(default_factory=list)

    @staticmethod
    def load(name: str) -> Base:
        path = HERE / "bases" / f"{name}.conf"
        if not path.is_file():
            sys.exit(f"no base {name}: {path} does not exist")
        base = Base(name, "", "")
        for raw in path.read_text().splitlines():
            line = raw.split(" # ", 1)[0].strip()
            if not line or line.startswith("#"):
                continue
            key, _, rest = line.partition(" ")
            rest = rest.strip()
            if key == "source":
                base.source = rest
            elif key == "url":
                base.url = rest
            elif key == "header":
                base.headers.append(rest)
            elif key == "render":
                base.renderers.update(rest.split())
            elif key == "cells":
                provider, props, prefixes = rest.split(None, 2)
                base.cells.append(Cells(provider, props.split(","), tuple(prefixes.split())))
            elif key == "decimal":
                base.decimal += rest.split()
            elif key == "gpio":
                base.gpio.update(rest.split())
            elif key == "ref":
                base.refs += rest.split()
            elif key == "rules":
                # a tree moved here from that base still carries its vendor's properties
                source = Base.load(rest)
                base.decimal += source.decimal
                base.gpio |= source.gpio
                base.refs += source.refs
            else:
                sys.exit(f"{path}: unknown key {key}")
        return base

    @cached_property
    def root(self) -> Path:
        """The include root, every header fetched into it once, kept per pin."""
        root = CACHE / f"{self.name}-{hashlib.sha256(self.url.encode()).hexdigest()[:12]}"
        for header in self.headers:
            target = root / header
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                body = fetch(f"{self.url}/{header}")
                # a symlink in the source tree comes back as the path it points to
                if "\n" not in body.strip() and not body.startswith("/*"):
                    body = fetch(f"{self.url}/{(Path(header).parent / body.strip())}")
                target.write_text(body)
        return root

    @cached_property
    def declared(self) -> dict[str, str]:
        """Each object-like macro's name, and the header that declares it."""
        root = self.root
        out: dict[str, str] = {}
        for header in self.headers:
            for name in DEFINE.findall((root / header).read_text()):
                out.setdefault(name, header)
        return out

    def defines(self) -> dict[str, int]:
        """Every object-like macro the headers define as a number, as cpp expands it."""
        root = self.root
        names = sorted(self.declared)
        probe = "".join(f"#include <{h}>\n" for h in self.headers)
        probe += "".join(f'"{n}" = {n}\n' for n in names)
        cmd = ["cc", "-E", "-P", "-nostdinc", "-undef", "-x", "c", "-I", str(root), "-"]
        expanded = run(cmd, probe.encode()).decode()
        out: dict[str, int] = {}
        for name, expression in re.findall(r'^"(\w+)" = (.+)$', expanded, re.M):
            value = arithmetic(expression)
            if value is not None:
                out[name] = value
        return out


def fetch(url: str) -> str:
    # posixpath-normalise the ../ a symlink target carries
    parts: list[str] = []
    for piece in url.split("/"):
        if piece == ".." and parts:
            parts.pop()
        elif piece != ".":
            parts.append(piece)
    url = "/".join(parts)
    for attempt in range(FETCH_ATTEMPTS):
        try:
            with urllib.request.urlopen(url) as response:
                return response.read().decode()
        except urllib.error.HTTPError as error:
            if error.code != HTTPStatus.TOO_MANY_REQUESTS:
                sys.exit(f"{url}: {error}")
            time.sleep(FETCH_BACKOFF_S * (attempt + 1))  # GitHub rate-limits raw files; it passes
    sys.exit(f"{url}: still rate-limited")


def run(cmd: list[str], stdin: bytes = b"") -> bytes:
    done = subprocess.run(cmd, input=stdin, capture_output=True)
    if done.returncode:
        sys.exit(f"{cmd[0]} failed:\n{done.stderr.decode()}")
    return done.stdout


def arithmetic(expression: str) -> int | None:
    """An integer constant expression's value, or None for anything else a macro expands to."""
    try:
        tree = ast.parse(re.sub(r"\b(0x[0-9a-fA-F]+|\d+)[uUlL]+\b", r"\1", expression), mode="eval")
    except SyntaxError:
        return None
    if not all(isinstance(n, ARITHMETIC) for n in ast.walk(tree)):
        return None
    value = eval(compile(tree, "<define>", "eval"))
    return value & CELL_MASK if isinstance(value, int) else None


def joined(text: str) -> str:
    """Each property spread over lines, by this formatting or by hand, back on one."""
    out: list[str] = []
    open_statement = False
    for line in text.split("\n"):
        if open_statement:
            out[-1] += " " + line.strip()
        else:
            out.append(line)
        if open_statement or PROPERTY_START.match(line):
            open_statement = not STATEMENT_END.search(line)
    return "\n".join(out)


def number(token: str) -> int | None:
    try:
        return int(token, 0)
    except ValueError:
        return None


class Tree:
    """The decompiled text, with what renderers need about its nodes: each line's node, what a
    reference token points at, and each node's effective interrupt parent."""

    def __init__(self, text: str) -> None:
        self.lines = text.split("\n")
        self.node_of: list[str] = []
        self.props: dict[str, dict[str, str]] = {}
        self.labels: dict[str, list[str]] = {}
        stack: list[str] = []
        for line in self.lines:
            t = line.strip()
            depth = len(line) - len(line.lstrip("\t"))
            if t.endswith("{"):
                stack = stack[:depth] + [t[:-1].strip()]
                self.props.setdefault(self.path(stack), {})
                self.labels[self.path(stack)] = re.findall(r"([\w-]+):\s", t)
            elif t == "};":
                stack = stack[:depth]
            m = PROPERTY.match(line) or FLAG.match(line)
            if m and stack:
                self.props[self.path(stack)][m.group(2)] = m.group(3) if m.re is PROPERTY else ""
            self.node_of.append(self.path(stack))

    @staticmethod
    def path(stack: list[str]) -> str:
        names = [re.sub(r"^([\w-]+:\s*)+", "", s) for s in stack[1:]]
        return "/" + "/".join(names)

    def references(self, node: str) -> set[str]:
        """The spellings dtc gives a reference to `node`: its labels, and its path."""
        return {f"&{{{node}}}"} | {f"&{label}" for label in self.labels.get(node, [])}

    def tokens(self, node: str) -> set[str]:
        """Every spelling a reference to `node` can take, a bare phandle too: one in a property
        dtc does not know holds a reference."""
        phandle = self.props.get(node, {}).get("phandle", "")
        return self.references(node) | set(re.findall(r"0x[0-9a-f]+", phandle))

    def find(self, pattern: str) -> list[str]:
        return [n for n in self.props if fnmatch(n.rsplit("/", 1)[-1], pattern)]

    def interrupt_parent(self, node: str) -> str:
        while True:
            value = self.props.get(node, {}).get("interrupt-parent")
            if value or node == "/":
                return (value or "").strip("<>")
            node = node.rsplit("/", 1)[0] or "/"


class Renderer:
    def __init__(self, base: Base, tree: Tree) -> None:
        self.base, self.tree = base, tree
        self.names = base.defines()
        self.declared = base.declared
        self.unnamed: list[str] = []
        self.named = 0
        self.by_value: dict[tuple[str, ...], dict[int, list[str]]] = {}
        self.providers: list[tuple[set[str], Cells]] = []
        for rule in base.cells:
            for node in tree.find(rule.provider):
                self.providers.append((tree.references(node), rule))
        self.gic = set().union(
            *[
                tree.tokens(n)
                for n in tree.props
                if "arm,gic" in tree.props[n].get("compatible", "")
                or "arm,cortex-a15-gic" in tree.props[n].get("compatible", "")
            ]
        )
        self.gpio = set().union(
            *[tree.tokens(n) for n in tree.props if "gpio-controller" in tree.props[n]]
        )
        # a vendor property dtc cannot know holds a reference keeps it as a bare phandle
        self.refs = {
            phandle: min(f"&{label}" for label in tree.labels[n] or [f"{{{n}}}"])
            for n in tree.props
            for phandle in re.findall(r"0x[0-9a-f]+", tree.props[n].get("phandle", ""))
        }

    def lookup(self, prefixes: tuple[str, ...], value: int) -> list[str]:
        table = self.by_value.get(prefixes)
        if table is None:
            table = {}
            headers = tuple(p for p in prefixes if p.endswith(".h"))
            names = tuple(p for p in prefixes if not p.endswith(".h"))
            for name, v in self.names.items():
                named = not names or name.startswith(names)
                if named and (not headers or self.declared.get(name) in headers):
                    table.setdefault(v, []).append(name)
            self.by_value[prefixes] = table
        return table.get(value, [])

    def decimal(self, node: str, prop: str) -> bool:
        if (prop.startswith("#") and prop.endswith("-cells")) or prop == "clock-frequency":
            return True
        if prop.endswith(UNIT_SUFFIXES) and prop != "opp-hz":
            return True
        for rule in list(DECIMAL) + self.base.decimal:
            where, _, name = rule.rpartition(":")
            # a node pattern matches the node's path, or its name alone
            here = where and (fnmatch(node, where) or fnmatch(node.rsplit("/", 1)[-1], where))
            if fnmatch(prop, name) and (not where or here):
                return True
        return False

    def group(self, node: str, prop: str, cells: list[str]) -> list[str]:
        out = list(cells)
        if "cells" in self.base.renderers:
            for i in range(len(out) - 1):
                for tokens, rule in self.providers:
                    if out[i] in tokens and prop in rule.props and number(out[i + 1]) is not None:
                        found = self.lookup(rule.prefixes, number(out[i + 1]) or 0)
                        if len(found) == 1:
                            out[i + 1] = found[0]
                            self.named += 1
                        else:
                            self.unnamed.append(f"{node} {prop} {out[i + 1]}: {found or 'no name'}")
        if "gpio-flags" in self.base.renderers and (
            prop in ("gpio", "gpios")
            or prop.endswith(("-gpio", "-gpios", "_gpio", "_gpios"))
            or prop in self.base.gpio
        ):
            for i in range(len(out) - 2):
                if out[i] in self.gpio and number(out[i + 1]) is not None:
                    out[i] = self.refs.get(out[i], out[i])
                    out[i + 1] = str(number(out[i + 1]))
                    flag = number(out[i + 2])
                    if flag in GPIO_FLAGS:
                        out[i + 2] = GPIO_FLAGS[flag]
        if any(fnmatch(prop, p) for p in self.base.refs) and all(c in self.refs for c in out):
            out = [self.refs[c] for c in out]
        if "gic" in self.base.renderers and prop == "interrupts":
            if self.tree.interrupt_parent(node) in self.gic or not self.gic:
                values = [number(c) for c in out]
                if len(out) % 3 == 0 and all(v is not None for v in values):
                    triples = [values[i : i + 3] for i in range(0, len(values), 3)]
                    if all(t[0] in GIC_TYPES and irq_type(t[2]) for t in triples):
                        out = [
                            x
                            for a, b, c in triples
                            for x in (GIC_TYPES[a or 0], str(b), irq_type(c))
                        ]
        if "rockchip-pins" in self.base.renderers and prop == "rockchip,pins":
            for i in range(0, len(out) - 3, 4):
                bank, pin, func = (number(c) for c in out[i : i + 3])
                if bank is not None and pin is not None and func is not None and pin < 32:
                    out[i] = str(bank)
                    out[i + 1] = f"RK_P{'ABCD'[pin // 8]}{pin % 8}"
                    out[i + 2] = "RK_FUNC_GPIO" if func == 0 else str(func)
        if "input-codes" in self.base.renderers and prop == "linux,code":
            for i, c in enumerate(out):
                v = number(c)
                found = self.lookup(("KEY_", "BTN_"), v) if v is not None else []
                if len(found) == 1:
                    out[i] = found[0]
        if "thermal" in self.base.renderers and prop == "cooling-device":
            out = ["THERMAL_NO_LIMIT" if c == "0xffffffff" else c for c in out]
        if self.decimal(node, prop):
            out = [str(number(c)) if c.startswith("0x") else c for c in out]
        if prop in DECIMAL_ARGS:
            after_ref = [any(t.startswith("&") for t in out[:i]) for i in range(len(out))]
            out = [
                str(number(c)) if c.startswith("0x") and a else c for c, a in zip(out, after_ref)
            ]
        return out

    def line(self, node: str, line: str) -> str:
        m = PROPERTY.match(line)
        if not m:
            return line
        indent, prop, value, rest = m.groups()
        if prop == "opp-hz" and "opp-hz" in self.base.renderers:
            cells = [number(c) for c in value.strip("<>").split()]
            if value.startswith("<") and len(cells) % 2 == 0 and all(c is not None for c in cells):
                hz = [(cells[i] or 0) << 32 | (cells[i + 1] or 0) for i in range(0, len(cells), 2)]
                return f"{indent}{prop} = /bits/ 64 <{' '.join(map(str, hz))}>;{rest}"
            return line
        if GROUPS.fullmatch(value):  # already split, one <> an entry: one list again
            value = "<" + " ".join(GROUP.findall(value)) + ">"
        whole = GROUP.fullmatch(value)
        value = GROUP.sub(
            lambda g: "<" + " ".join(self.group(node, prop, g.group(1).split())) + ">", value
        )
        if whole:
            entries = split(TOKEN.findall(value[1:-1]), prop, self.entries(node, prop))
            if len(entries) > 1:
                one = f"{indent}{prop} = " + ", ".join(f"<{e}>" for e in entries) + f";{rest}"
                if len(one.expandtabs(8)) <= WIDTH:
                    return one
                pad = f",\n{indent}{' ' * (len(prop) + 3)}"
                return f"{indent}{prop} = " + pad.join(f"<{e}>" for e in entries) + f";{rest}"
        return f"{indent}{prop} = {value};{rest}"

    def entries(self, node: str, prop: str) -> int:
        """How many entries prop holds, where a sibling says: its -names, or for a rate its
        clock."""
        props = self.tree.props.get(node, {})
        if prop == "assigned-clock-rates":
            return props.get("assigned-clocks", "").count("&")
        return len(re.findall(r'"[^"]*"', props.get(names_of(prop), "")))

    def render(self) -> str:
        lines = [
            self.line(n, l)
            for n, l in zip(self.tree.node_of, self.tree.lines)
            if not l.startswith(("/* dt-bindings from ", "#include <"))
        ]
        head = f"/* dt-bindings from {self.base.source} */\n" + "".join(
            f"#include <{h}>\n" for h in self.base.headers
        )
        text = re.sub(r"\A/dts-v1/;\n\n+", "/dts-v1/;\n\n", "\n".join(lines))
        return text.replace("/dts-v1/;\n\n", f"/dts-v1/;\n\n{head}\n", 1)


def irq_type(cell: int | None) -> str:
    """A GIC interrupt's type cell, the CPU mask its second byte may carry written as mainline does;
    empty if it is not one."""
    if cell is None or cell & 0xFF not in IRQ_TYPES or cell >> 16:
        return ""
    mask, kind = cell >> 8, IRQ_TYPES[cell & 0xFF]
    if not mask:
        return kind
    cpus = mask.bit_length()
    return f"(GIC_CPU_MASK_SIMPLE({cpus}) | {kind})" if mask == (1 << cpus) - 1 else ""


def names_of(prop: str) -> str:
    """The property that names prop's entries: clock-names for clocks, reg-names for reg."""
    if prop == "mboxes":
        return "mbox-names"
    return (prop[:-1] if prop.endswith("s") else prop) + "-names"


def split(tokens: list[str], prop: str, count: int) -> list[str]:
    """One entry a group: as many as its -names property names, or else a specifier from one
    reference to the next, an interrupt under the GIC, a pin. Anything else is one group."""
    if count > 1 and len(tokens) % count == 0:
        width = len(tokens) // count
        entries = [tokens[i : i + width] for i in range(0, len(tokens), width)]
        if not tokens[0].startswith("&") or all(e[0].startswith("&") for e in entries):
            return [" ".join(e) for e in entries]
    if prop == "rockchip,pins" and len(tokens) % 4 == 0:
        return [" ".join(tokens[i : i + 4]) for i in range(0, len(tokens), 4)]
    if tokens and tokens[0] in GIC_TYPES.values() and len(tokens) % 3 == 0:
        if all(tokens[i] in GIC_TYPES.values() for i in range(0, len(tokens), 3)):
            return [" ".join(tokens[i : i + 3]) for i in range(0, len(tokens), 3)]
    if tokens and tokens[0].startswith("&"):
        entries: list[list[str]] = []
        for token in tokens:
            if token.startswith("&"):
                entries.append([])
            entries[-1].append(token)
        return [" ".join(e) for e in entries]
    return [" ".join(tokens)]


def decompile(blob: bytes, symbols: bool) -> str:
    return run(
        [DTC, "-q", "-P", *([] if symbols else ["-n"]), "-I", "dtb", "-O", "dts"], blob
    ).decode()


def compile_tree(text: str, root: Path, symbols: bool) -> bytes:
    cpp = [
        "cc",
        "-E",
        "-nostdinc",
        "-undef",
        "-D__DTS__",
        "-x",
        "assembler-with-cpp",
        "-P",
        "-I",
        str(root),
        "-",
    ]
    return run(
        [DTC, "-q", *([] if symbols else ["-@"]), "-I", "dts", "-O", "dtb"], run(cpp, text.encode())
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-n",
        dest="no_symbols",
        action="store_true",
        help="drop __symbols__, as dtc -n; the round trip rebuilds them with -@",
    )
    parser.add_argument("--strict", action="store_true", help="refuse a cell left unnamed")
    parser.add_argument("--render", action="store_true", help="render a .dts as it is")
    parser.add_argument("--include", action="store_true", help="print the base's include root")
    parser.add_argument("base")
    parser.add_argument("input", nargs="?")
    args = parser.parse_args()

    base = Base.load(args.base)
    if args.include:
        print(base.root)
        return
    if not args.input:
        parser.error("name the blob, or the tree to render")
    if args.render:
        renderer = Renderer(base, Tree(joined(Path(args.input).read_text())))
        sys.stdout.write(renderer.render())
        return
    blob = Path(args.input).read_bytes()
    raw = decompile(blob, not args.no_symbols)
    renderer = Renderer(base, Tree(raw))
    text = renderer.render()
    if args.strict and renderer.unnamed:
        sys.exit("cells with no single name:\n  " + "\n  ".join(sorted(set(renderer.unnamed))))
    if decompile(compile_tree(text, base.root, not args.no_symbols), not args.no_symbols) != raw:
        sys.exit("the rendered tree does not decompile back to the blob's own, refusing")
    print(
        f"  {renderer.named} cells named, {len(set(renderer.unnamed))} left as numbers",
        file=sys.stderr,
    )
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
