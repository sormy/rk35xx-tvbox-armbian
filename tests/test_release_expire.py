"""release/expire.py against hand-made indexes: a 30-day window, today 2026-12-01.

Needs dpkg, for version order: ./build.sh test runs it in the build container.
"""

from __future__ import annotations

import datetime
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
import expire  # noqa: E402  # release/ is scripts, not a package
from expire import Stanza, contents  # noqa: E402

TODAY = datetime.date(2026, 12, 1)
KEEP_DAYS = 30  # the cutoff is 2026-11-01
OLD, RECENT = "2026-06-01", "2026-11-20"
Kept = set[tuple[str, str]]


def deb(package: str, version: str, day: str = "", depends: str = "") -> Stanza:
    lines = [f"Package: {package}", f"Version: {version}", f"Filename: ./{package}_{version}.deb"]
    lines += [f"Depends: {depends}"] if depends else []
    lines += [f"X-Tvb-Published: {day}"] if day else []
    return Stanza("\n".join(lines))


def kernel(meta: str, release: str, revision: str, day: str) -> list[Stanza]:
    """A kernel release's image, headers and driver, and the metapackage pinning them."""
    version, named = f"{release}-{revision}", f"{release}-tvb-rk35xx"
    image, driver = f"linux-image-{named}", f"tvb-aic8800-modules-{named}"
    pins = f"{image} (= {version}), {driver} (= {version})"
    headers = f"linux-headers-{named}"
    return [deb(image, version, day), deb(headers, version, day), deb(driver, version, day)] + [
        deb(meta, version, day, pins)
    ]


def kept(stanzas: list[Stanza]) -> Kept:
    return {(s.package, s.version) for s in stanzas}


def versions(package: str, *each: str) -> Kept:
    return {(package, v) for v in each}


DEFAULT, NEXT = "linux-image-tvb-rk35xx", "linux-image-tvb-rk35xx-next"
R69 = "tvb-r69"
CASES: list[tuple[str, list[Stanza], Kept]] = [
    ("a single version older than the window stays", [deb(R69, "1", OLD)], versions(R69, "1")),
    (
        "of three versions replaced long ago, only the newest stays",
        [deb(R69, v, OLD) for v in ("1", "2", "3")],
        versions(R69, "3"),
    ),
    (
        "dpkg order, not string order: 10 is newer than 9",
        [deb(R69, v, OLD) for v in ("9", "10")],
        versions(R69, "10"),
    ),
    (
        "a version replaced inside the window stays, however old it is",
        [deb(R69, "1", OLD), deb(R69, "2", RECENT), deb(R69, "3", RECENT)],
        versions(R69, "1", "2", "3"),
    ),
    (
        "a version replaced before the window goes",
        [deb(R69, "1", OLD), deb(R69, "2", OLD), deb(R69, "3", RECENT)],
        versions(R69, "2", "3"),
    ),
    (
        "newest for months, replaced today: it stays",
        [deb("tvb-archive-keyring", "1", OLD), deb("tvb-archive-keyring", "2")],
        versions("tvb-archive-keyring", "1", "2"),
    ),
    (
        "unstamped: every version is today's, so all of them stay",
        [deb(R69, v) for v in ("1", "2", "3")],
        versions(R69, "1", "2", "3"),
    ),
    (
        "an unstamped version replaced long ago goes",
        [deb(R69, "1"), deb(R69, "2", OLD)],
        versions(R69, "2"),
    ),
    (
        "the window's edge: replaced 30 days ago stays, 31 goes",
        [deb(R69, "1", OLD), deb(R69, "2", "2026-10-31"), deb(R69, "3", "2026-11-01")],
        versions(R69, "2", "3"),
    ),
    (
        "an old kernel the metapackage pins stays, with its headers and driver",
        kernel(DEFAULT, "6.1.172", "2", OLD),
        kept(kernel(DEFAULT, "6.1.172", "2", OLD)),
    ),
    (
        "a kernel replaced long ago goes; the metapackage's kernel stays",
        kernel(DEFAULT, "6.1.170", "1", OLD) + kernel(DEFAULT, "6.1.172", "1", OLD),
        kept(kernel(DEFAULT, "6.1.172", "1", OLD)),
    ),
    (
        "a kernel replaced inside the window stays, for apt install to go back to",
        kernel(DEFAULT, "6.1.170", "1", OLD) + kernel(DEFAULT, "6.1.172", "1", RECENT),
        kept(kernel(DEFAULT, "6.1.170", "1", OLD) + kernel(DEFAULT, "6.1.172", "1", RECENT)),
    ),
    (
        "a kernel current for months, replaced today, stays",
        kernel(DEFAULT, "6.1.172", "1", OLD) + kernel(DEFAULT, "6.1.173", "1", ""),
        kept(kernel(DEFAULT, "6.1.172", "1", OLD) + kernel(DEFAULT, "6.1.173", "1", "")),
    ),
    (
        "an unstamped kernel replaced long ago goes",
        kernel(DEFAULT, "6.1.170", "1", "") + kernel(DEFAULT, "6.1.172", "1", OLD),
        kept(kernel(DEFAULT, "6.1.172", "1", OLD)),
    ),
    (
        "default and -next share a name suffix: each keeps the kernel it pins",
        kernel(DEFAULT, "6.1.172", "2", OLD) + kernel(NEXT, "6.12.69", "2", OLD),
        kept(kernel(DEFAULT, "6.1.172", "2", OLD) + kernel(NEXT, "6.12.69", "2", OLD)),
    ),
    (
        "an old kernel revision goes once its metapackage moved on long ago",
        kernel(DEFAULT, "6.1.172", "1", OLD) + kernel(DEFAULT, "6.1.172", "2", OLD),
        kept(kernel(DEFAULT, "6.1.172", "2", OLD)),
    ),
    (
        "an -rc kernel's packages count as a kernel's, and expire with it",
        kernel(DEFAULT, "6.13.0-rc1", "1", OLD) + kernel(DEFAULT, "6.13.0-rc2", "1", OLD),
        kept(kernel(DEFAULT, "6.13.0-rc2", "1", OLD)),
    ),
    (
        "a loose Depends keeps only the newest it allows",
        [deb("tvb-base", v, OLD) for v in ("1", "2", "3")]
        + [deb(R69, "5", OLD, "tvb-base (>= 1)")],
        versions("tvb-base", "3") | versions(R69, "5"),
    ),
    (
        "an exact pin to an old version keeps it beside the newest",
        [deb("tvb-base", v, OLD) for v in ("1", "2", "3")] + [deb(R69, "5", OLD, "tvb-base (= 2)")],
        versions("tvb-base", "2", "3") | versions(R69, "5"),
    ),
]


class ExpireTest(unittest.TestCase):
    def test_cases(self) -> None:
        for name, index, want in CASES:
            with self.subTest(name):
                self.assertEqual(kept(expire.expire(index, TODAY, KEEP_DAYS)), want)

    def test_a_deb_this_run_ships_stays_whatever_its_age(self) -> None:
        index = [deb(R69, v, OLD) for v in ("1", "2", "3")]
        out = expire.expire(index, TODAY, KEEP_DAYS, frozenset({"tvb-r69_1.deb"}))
        self.assertEqual(kept(out), versions(R69, "1", "3"))

    def test_a_deb_in_both_indexes_is_listed_once_with_its_published_stamp(self) -> None:
        out = expire.expire([deb(R69, "1", OLD), deb(R69, "1")], TODAY, KEEP_DAYS)
        self.assertEqual([(s.version, s.published) for s in out], [("1", OLD)])

    def test_unstamped_stanzas_are_stamped_today(self) -> None:
        out = expire.expire([deb(R69, "1", OLD), deb(R69, "2")], TODAY, KEEP_DAYS)
        self.assertEqual({(s.version, s.published) for s in out}, {("1", OLD), ("2", "2026-12-01")})

    def test_an_unstamped_index_expires_from_the_day_it_was_stamped(self) -> None:
        """The first run with expiry stamps the published index; a later run expires from that."""
        index = [deb(R69, v) for v in ("1", "2")] + kernel(DEFAULT, "6.1.170", "1", "")
        index += kernel(DEFAULT, "6.1.172", "1", "")
        first = expire.expire(index, TODAY, KEEP_DAYS)
        self.assertEqual(kept(first), kept(index))
        within = expire.expire(first, TODAY + datetime.timedelta(days=KEEP_DAYS), KEEP_DAYS)
        self.assertEqual(kept(within), kept(index))
        later = expire.expire(first, TODAY + datetime.timedelta(days=KEEP_DAYS + 1), KEEP_DAYS)
        self.assertEqual(
            kept(later), versions(R69, "2") | kept(kernel(DEFAULT, "6.1.172", "1", ""))
        )

    def test_kernel_release_names(self) -> None:
        named = {
            "linux-image-6.1.172-tvb-rk35xx": "6.1.172-tvb-rk35xx",
            "tvb-aic8800-modules-6.12.69-tvb-rk35xx": "6.12.69-tvb-rk35xx",
            "linux-headers-6.13.0-rc1-tvb-meson64": "6.13.0-rc1-tvb-meson64",
            "linux-image-tvb-rk35xx-next": "",
            "tvb-firmware-aic8800": "",
            "tvb-base": "",
        }
        for package, release in named.items():
            with self.subTest(package):
                self.assertEqual(deb(package, "1").release, release)


class ContentsTest(unittest.TestCase):
    BOARDS = "tvb-h96max-3518d,tvb-r69"

    def test_a_shared_path_keeps_every_owner_still_indexed(self) -> None:
        out = contents(f"etc/motd {self.BOARDS}\n", "", set(), {"tvb-h96max-3518d", "tvb-r69"})
        self.assertEqual(out, f"etc/motd {self.BOARDS}\n")

    def test_a_rebuilt_owner_comes_from_the_new_contents_once(self) -> None:
        out = contents(
            f"etc/motd {self.BOARDS}\n",
            "etc/motd tvb-r69\n",
            {"tvb-r69"},
            {"tvb-h96max-3518d", "tvb-r69"},
        )
        self.assertEqual(out, f"etc/motd {self.BOARDS}\n")

    def test_an_expired_owner_leaves_the_line_and_an_ownerless_line_goes(self) -> None:
        published = f"etc/motd {self.BOARDS}\nusr/lib/old tvb-gone\n"
        out = contents(published, "", set(), {"tvb-r69"})
        self.assertEqual(out, "etc/motd tvb-r69\n")

    def test_apt_ftparchive_padding_before_the_owner(self) -> None:
        out = contents("etc/motd\t\t\t    tvb-r69\n", "a/long/path tvb-base\n", set(), {"tvb-r69"})
        self.assertEqual(out, "a/long/path tvb-base\netc/motd tvb-r69\n")

    def test_a_section_before_the_package_is_read_past(self) -> None:
        out = contents("etc/motd admin/tvb-r69\n", "", set(), {"tvb-r69"})
        self.assertEqual(out, "etc/motd tvb-r69\n")


class MainTest(unittest.TestCase):
    def test_main_reads_the_release_dir_and_writes_the_repo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            release, debs, repo = (Path(tmp) / d for d in ("release", "debs", "repo"))
            for d in (release, debs, repo):
                d.mkdir()
            (release / "Packages.published").write_text(f"{deb(R69, '1', OLD).text}\n")
            (release / "Packages.new").write_text(f"{deb(R69, '2').text}\n")
            (release / "Contents.published").write_text("etc/motd tvb-r69\n")
            (release / "Contents.new").write_text("etc/issue tvb-base\netc/motd tvb-r69\n")
            (debs / "tvb-r69_2.deb").write_bytes(b"")
            argv = ["expire.py", str(release), str(debs), str(repo)]
            with mock.patch.dict(os.environ, {"TVB_APT_KEEP_DAYS": str(KEEP_DAYS)}):
                with mock.patch.object(sys, "argv", argv):
                    expire.main()
            written = expire.parse((repo / "Packages").read_text())
            self.assertEqual(kept(written), versions(R69, "1", "2"))
            self.assertTrue(all(s.published for s in written))
            self.assertEqual(
                (repo / "Contents").read_text(), "etc/issue tvb-base\netc/motd tvb-r69\n"
            )

    def test_main_refuses_without_the_window(self) -> None:
        with mock.patch.dict(os.environ, clear=True), self.assertRaises(SystemExit):
            expire.main()


if __name__ == "__main__":
    unittest.main()
