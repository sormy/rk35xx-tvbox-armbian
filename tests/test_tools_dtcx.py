"""tools/dtcx/dtcx.py's rendering, on hand-made trees and headers. Needs cc, for the header values:
./build.sh test runs it in the build container, and the runner has one."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools/dtcx"))
from dtcx import (  # noqa: E402
    Base,
    Cells,
    Renderer,
    Tree,
    arithmetic,
    irq_type,
    joined,
    names_of,
    split,
)

HEADERS = {
    "dt-bindings/clock/test.h": "#define CLK_A 1\n#define CLK_B (CLK_A + 1)\n"
    "#define CLK_TWIN1 5\n#define CLK_TWIN2 5\n",
    "dt-bindings/input/linux-event-codes.h": "#define KEY_POWER 116\n"
    "#define KEY_X 50\n#define KEY_Y 50\n",
}
TREE = """/dts-v1/;

/ {
\tinterrupt-parent = <&gic>;

\tgic: interrupt-controller@1 {
\t\tcompatible = "arm,gic-400";
\t\tphandle = <0x01>;
\t};

\tcru: clock-controller@2 {
\t\tphandle = <0x02>;
\t};

\tgpio0: gpio@3 {
\t\tgpio-controller;
\t\tphandle = <0x03>;
\t};

\tdev@4 {
\t\tclocks = <&cru 0x01 &cru 0x02>;
\t\tclock-names = "a", "b";
\t\tassigned-clocks = <&cru 0x05>;
\t\tinterrupts = <0x00 0x20 0x04>;
\t\treset-gpios = <&gpio0 0x0a 0x01>;
\t\tstartup-delay-us = <0x64>;
\t\tlinux,code = <0x74>;
\t\tkey-twin = <0x32>;
\t\tdmas = <&cru 0x0c>;
\t\tmagic = <0x5242c300>;
\t};
};
"""


def rendered(
    tree: str = TREE,
    renderers: frozenset[str] = frozenset({"cells", "gpio-flags", "gic", "input-codes"}),
    prefixes: tuple[str, ...] = ("CLK_",),
) -> tuple[dict[str, str], Renderer]:
    """Each property's rendered line, by name, and the renderer that made them: the clock
    controller's cells named from prefixes."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in HEADERS.items():
            (Path(tmp) / name).parent.mkdir(parents=True, exist_ok=True)
            (Path(tmp) / name).write_text(body)
        base = Base("test", "test headers", "", headers=list(HEADERS))
        base.renderers = set(renderers)
        base.cells = [Cells("clock-controller@2", ["clocks", "assigned-clocks"], prefixes)]
        base.__dict__["root"] = Path(tmp)  # the headers here, not fetched
        renderer = Renderer(base, Tree(tree))
        text = renderer.render()
    lines = {
        line.strip().split(" = ")[0]: line.strip() for line in text.splitlines() if " = " in line
    }
    return lines, renderer


class ArithmeticTest(unittest.TestCase):
    def test_c_integer_expressions(self) -> None:
        cases: dict[str, int | None] = {
            "(1 << 3)": 8,
            "((25 + 25) + 14)": 64,
            "0x10UL": 16,
            "(2 | 4)": 6,
            "~0": 0xFFFFFFFF,
            "-1": 0xFFFFFFFF,
            "4 / 2": None,  # Python's division is not C's
            "7 % 2": None,
            "2 ** 3": None,
            "__import__('os')": None,
            "CLK_A": None,
            "1 +": None,
        }
        for expression, value in cases.items():
            with self.subTest(expression):
                self.assertEqual(arithmetic(expression), value)


class JoinedTest(unittest.TestCase):
    def test_a_property_over_lines_is_one_line(self) -> None:
        self.assertEqual(
            joined("\tclocks = <&a 1>,\n\t\t <&b 2>;\n"), "\tclocks = <&a 1>, <&b 2>;\n"
        )

    def test_a_path_reference_braces_do_not_end_it(self) -> None:
        text = "\tclocks = <&{/clock-controller@1} 1>,\n\t\t <&{/clock-controller@1} 2>;"
        self.assertEqual(
            joined(text), "\tclocks = <&{/clock-controller@1} 1>, <&{/clock-controller@1} 2>;"
        )

    def test_a_trailing_comment_ends_a_statement(self) -> None:
        text = '\tstatus = "okay"; /* why */\n\tnext = <1>;'
        self.assertEqual(joined(text), text)

    def test_nodes_and_comments_are_left_alone(self) -> None:
        text = "\tnode {\n\t\t/* a = b,\n\t\t   c */\n\t};"
        self.assertEqual(joined(text), text)


class SplitTest(unittest.TestCase):
    def test_entries(self) -> None:
        cases: list[tuple[str, list[str], str, int, list[str]]] = [
            ("by -names", ["&cru", "A", "&cru", "B"], "clocks", 2, ["&cru A", "&cru B"]),
            (
                "by -names, without references",
                ["0x0", "0x1000", "0x0", "0x2000"],
                "reg",
                2,
                ["0x0 0x1000", "0x0 0x2000"],
            ),
            ("by reference", ["&a", "1", "&b", "2", "3"], "pwms", 0, ["&a 1", "&b 2 3"]),
            (
                "by pin",
                ["1", "2", "3", "&p", "4", "5", "6", "&q"],
                "rockchip,pins",
                0,
                ["1 2 3 &p", "4 5 6 &q"],
            ),
            (
                "by interrupt",
                ["GIC_SPI", "1", "X", "GIC_PPI", "2", "Y"],
                "interrupts",
                0,
                ["GIC_SPI 1 X", "GIC_PPI 2 Y"],
            ),
            ("one value", ["1", "2"], "reg", 0, ["1 2"]),
        ]
        for name, tokens, prop, count, want in cases:
            with self.subTest(name):
                self.assertEqual(split(tokens, prop, count), want)

    def test_names_of(self) -> None:
        for prop, names in {
            "clocks": "clock-names",
            "mboxes": "mbox-names",
            "reg": "reg-names",
        }.items():
            with self.subTest(prop):
                self.assertEqual(names_of(prop), names)


class IrqTypeTest(unittest.TestCase):
    def test_cells(self) -> None:
        cases: dict[int | None, str] = {
            4: "IRQ_TYPE_LEVEL_HIGH",
            8: "IRQ_TYPE_LEVEL_LOW",
            0xF04: "(GIC_CPU_MASK_SIMPLE(4) | IRQ_TYPE_LEVEL_HIGH)",
            0x504: "",  # not a run of CPUs from 0
            3: "",
            0x10004: "",
            None: "",
        }
        for cell, name in cases.items():
            with self.subTest(cell):
                self.assertEqual(irq_type(cell), name)


class TreeTest(unittest.TestCase):
    def test_paths_labels_and_the_interrupt_parent(self) -> None:
        tree = Tree(TREE)
        self.assertIn("/dev@4", tree.props)
        self.assertEqual(tree.labels["/gpio@3"], ["gpio0"])
        self.assertEqual(tree.references("/gpio@3"), {"&gpio0", "&{/gpio@3}"})
        self.assertEqual(tree.interrupt_parent("/dev@4"), "&gic")


class RendererTest(unittest.TestCase):
    def test_rendered_properties(self) -> None:
        lines, _ = rendered()
        cases = {
            "clocks": "clocks = <&cru CLK_A>, <&cru CLK_B>;",
            "interrupts": "interrupts = <GIC_SPI 32 IRQ_TYPE_LEVEL_HIGH>;",
            "reset-gpios": "reset-gpios = <&gpio0 10 GPIO_ACTIVE_LOW>;",
            "startup-delay-us": "startup-delay-us = <100>;",
            "linux,code": "linux,code = <KEY_POWER>;",
            "dmas": "dmas = <&cru 12>;",
            "magic": "magic = <0x5242c300>;",
        }
        for prop, line in cases.items():
            with self.subTest(prop):
                self.assertEqual(lines[prop], line)

    def test_a_value_with_two_names_stays_a_number_and_is_counted(self) -> None:
        lines, renderer = rendered()
        self.assertEqual(lines["assigned-clocks"], "assigned-clocks = <&cru 5>;")
        self.assertTrue(any("assigned-clocks" in u for u in renderer.unnamed))

    def test_a_key_code_with_two_names_is_counted(self) -> None:
        tree = TREE.replace("linux,code = <0x74>", "linux,code = <0x32>")
        _, renderer = rendered(tree)
        self.assertTrue(any("linux,code" in u for u in renderer.unnamed))

    def test_a_header_limited_rule_names_only_that_header(self) -> None:
        only_input = ("dt-bindings/input/linux-event-codes.h", "")
        lines, _ = rendered(renderers=frozenset({"cells"}), prefixes=only_input)
        self.assertEqual(lines["clocks"], "clocks = <&cru 1>, <&cru 2>;")  # CLK_A, CLK_B unused


if __name__ == "__main__":
    unittest.main()
