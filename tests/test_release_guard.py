"""release/guard.sh on real debs against a hand-made published Contents.

Needs dpkg-deb, to build them: ./build.sh test runs it in the build container.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release/guard.sh"
PATH = "usr/lib/tvb/journal-spill"


def build(debs: Path, package: str, version: str, fields: str = "") -> str:
    """A deb shipping PATH, with extra control fields; its file name."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / PATH).parent.mkdir(parents=True)
        (root / PATH).write_text("x\n")
        (root / "DEBIAN").mkdir()
        control = f"Package: {package}\nVersion: {version}\nArchitecture: all\n{fields}"
        control += "Maintainer: t <t@t>\nDescription: t\n"
        (root / "DEBIAN/control").write_text(control)
        name = f"{package}_{version}_all.deb"
        subprocess.run(
            ["dpkg-deb", "-b", str(root), str(debs / name)], check=True, capture_output=True
        )
    return name


class GuardTest(unittest.TestCase):
    def guard(self, published: str, published_debs: list[str], new: list[tuple[str, str]]) -> int:
        """Exit status of the guard: published owners in Contents, then this run's debs."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "release").mkdir()
            (out / "debs").mkdir()
            (out / "release/Contents.published").write_text(published)
            index = "".join(
                f"Package: {n.split('_')[0]}\nFilename: ./{n}\n\n" for n in published_debs
            )
            (out / "release/Packages.published").write_text(index)
            for package, fields in new:
                build(out / "debs", package, "2", fields)
            for name in published_debs:
                package, version = name.split("_")[:2]
                build(out / "debs", package, version)
            run = subprocess.run(["bash", str(SCRIPT), str(out)], capture_output=True, text=True)
            return run.returncode

    def test_moves(self) -> None:
        owned = f"{PATH} tvb-r69\n"
        cases: list[tuple[str, str, list[str], list[tuple[str, str]], int]] = [
            ("nothing published to move from", "", [], [("tvb-base", "")], 0),
            ("a path taken unannounced fails", owned, [], [("tvb-base", "")], 1),
            ("only Replaces is not enough", owned, [], [("tvb-base", "Replaces: tvb-r69\n")], 1),
            (
                "Replaces and Breaks announce the move",
                owned,
                [],
                [("tvb-base", "Replaces: tvb-r69 (<< 2)\nBreaks: tvb-r69 (<< 2)\n")],
                0,
            ),
            (
                "a package conflicting with the owner never shares a box",
                owned,
                [],
                [("tvb-base", "Conflicts: tvb-r69\n")],
                0,
            ),
            ("its own path is no move", owned, [], [("tvb-r69", "")], 0),
            (
                "a deb already published moved nothing this run",
                owned,
                ["tvb-base_1_all.deb"],
                [],
                0,
            ),
        ]
        for name, published, published_debs, new, status in cases:
            with self.subTest(name):
                self.assertEqual(self.guard(published, published_debs, new), status)


if __name__ == "__main__":
    unittest.main()
