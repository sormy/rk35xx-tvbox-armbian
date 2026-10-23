"""release/verify.py's checks against a repo held in memory: no network, no signing key."""

from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
from verify import Repo  # noqa: E402

Stanza = dict[str, str]


class Served(Repo):
    """A repo whose files are a dict, served at their size unless sizes says otherwise."""

    def __init__(self, files: dict[str, bytes], sizes: dict[str, int | None] | None = None) -> None:
        super().__init__("memory")
        self.files, self.sizes = files, sizes or {}

    def get(self, name: str) -> bytes:
        return self.files[name]

    def fail(self, problem: str) -> None:
        self.problems.append(problem)  # recorded, not printed

    def served_size(self, name: str) -> int | None:
        return self.sizes.get(name, len(self.files[name]) if name in self.files else None)


def release_for(files: dict[str, bytes]) -> str:
    lines = [f" {hashlib.sha256(d).hexdigest()} {len(d)} {n}" for n, d in files.items()]
    return "Origin: TVBian\nSHA256:\n" + "\n".join(lines) + "\n"


def stanza(package: str, version: str, depends: str = "", provides: str = "") -> Stanza:
    out = {
        "Package": package,
        "Version": version,
        "Filename": f"./{package}_{version}.deb",
        "Size": "1",
    }
    return (
        out
        | ({"Depends": depends} if depends else {})
        | ({"Provides": provides} if provides else {})
    )


INDEX = {"Packages": b"P", "Packages.xz": b"X", "Contents": b"C"}


class IndexTest(unittest.TestCase):
    def test_an_index_matching_release_passes(self) -> None:
        repo = Served(dict(INDEX))
        repo.check_index(release_for(INDEX))
        self.assertEqual(repo.problems, [])

    def test_a_file_not_in_release_fails(self) -> None:
        repo = Served(dict(INDEX))
        repo.check_index(release_for({k: v for k, v in INDEX.items() if k != "Contents"}))
        self.assertEqual(repo.problems, ["Contents is not listed in Release"])

    def test_a_file_changed_since_release_fails(self) -> None:
        repo = Served(INDEX | {"Packages": b"changed"})
        repo.check_index(release_for(INDEX))
        self.assertEqual(repo.problems, ["Packages does not match its Release entry"])


class FilesTest(unittest.TestCase):
    def test_every_deb_served_at_its_size_passes(self) -> None:
        repo = Served({"a_1.deb": b"x"})
        repo.check_files([stanza("a", "1")])
        self.assertEqual(repo.problems, [])

    def test_a_missing_or_resized_deb_fails(self) -> None:
        cases: list[tuple[str, dict[str, int | None]]] = [
            ("missing", {"a_1.deb": None}),
            ("resized", {"a_1.deb": 7}),
        ]
        for name, sizes in cases:
            with self.subTest(name):
                repo = Served({"a_1.deb": b"x"}, sizes)
                repo.check_files([stanza("a", "1")])
                self.assertEqual(len(repo.problems), 1)


class DependsTest(unittest.TestCase):
    def check(self, stanzas: list[Stanza]) -> list[str]:
        repo = Served({})
        repo.check_depends(stanzas)
        return repo.problems

    def test_dependencies(self) -> None:
        base, meta = stanza("tvb-base", "1"), "linux-image-tvb-rk35xx"
        image = stanza("linux-image-6.1.172-tvb-rk35xx", "6.1.172-2")
        pinned = f"{image['Package']} (= 6.1.172-2)"
        cases: list[tuple[str, list[Stanza], int]] = [
            ("present", [base, stanza("tvb-r69", "2", "tvb-base")], 0),
            ("absent", [stanza("tvb-r69", "2", "tvb-base")], 1),
            ("an exact pin, served", [image, stanza(meta, "6.1.172-2", pinned)], 0),
            (
                "an exact pin, another version served",
                [image | {"Version": "6.1.172-1"}, stanza(meta, "6.1.172-2", pinned)],
                1,
            ),
            (
                "a loose relation needs only the name",
                [base, stanza("tvb-r69", "2", "tvb-base (>= 9)")],
                0,
            ),
            (
                "a virtual package someone provides",
                [stanza("tvb-r69", "2", provides="tvb-board"), stanza("x", "1", "tvb-board")],
                0,
            ),
            (
                "Debian's packages are not ours to check",
                [stanza("tvb-r69", "2", "u-boot-menu, bluez")],
                0,
            ),
            (
                "an alternative is judged by its first",
                [base, stanza("tvb-r69", "2", "tvb-base | tvb-gone")],
                0,
            ),
        ]
        for name, stanzas, problems in cases:
            with self.subTest(name):
                self.assertEqual(len(self.check(stanzas)), problems)


if __name__ == "__main__":
    unittest.main()
