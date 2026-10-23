"""package/install-list.sh, run as the package steps run it, into a scratch root."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "package/install-list.sh"


class InstallListTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(scratch.name)

    def install(
        self, listing: str, sources: dict[str, str]
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        """Run the script on listing, its sources written first; its result, and the root."""
        src, root, listed = self.tmp / "src", self.tmp / "root", self.tmp / "package.list"
        for name, body in sources.items():
            (src / name).parent.mkdir(parents=True, exist_ok=True)
            (src / name).write_text(body)
        listed.write_text(listing)
        run = subprocess.run(
            ["bash", str(SCRIPT), str(listed), str(src), str(root)], capture_output=True, text=True
        )
        return run, root

    def test_files_links_and_comments(self) -> None:
        listing = (
            "# a comment line\n\n"
            "0644 conf.d/a.conf   /usr/lib/x/a.conf\n"
            "0755 tool            /usr/lib/x/tool   # a trailing comment\n"
            "link ../tool         /usr/lib/x/bin/tool"  # no newline at the end
        )
        run, root = self.install(listing, {"conf.d/a.conf": "a\n", "tool": "#!/bin/sh\n"})
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual((root / "usr/lib/x/a.conf").read_text(), "a\n")
        self.assertEqual(oct((root / "usr/lib/x/a.conf").stat().st_mode & 0o777), "0o644")
        self.assertEqual(oct((root / "usr/lib/x/tool").stat().st_mode & 0o777), "0o755")
        self.assertEqual(os.readlink(root / "usr/lib/x/bin/tool"), "../tool")
        self.assertEqual(
            sorted(p.name for p in (root / "usr/lib/x").iterdir()), ["a.conf", "bin", "tool"]
        )

    def test_a_missing_source_fails(self) -> None:
        run, _ = self.install("0644 absent /usr/lib/x/absent\n", {})
        self.assertNotEqual(run.returncode, 0)


if __name__ == "__main__":
    unittest.main()
