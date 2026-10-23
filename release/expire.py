#!/usr/bin/env python3
"""Merge the published index with this run's new debs, expiring what the repo no longer needs.

A package's newest version stays; an older one stays TVB_APT_KEEP_DAYS after a newer one was
published, so going back stays possible that long after an upgrade. A package named for a kernel
release (linux-image-6.1.172-tvb-rk35xx, its headers, its drivers) stays while what it serves
stays: by a kept package's Depends, or beside a kept package of the same release and version. A deb
this run built or reused always stays: the images are made of them.

  Usage: expire.py [--keep-all] <release dir> <debs dir> <repo dir>   (inside the build container)
  --keep-all: a run that publishes nothing expires nothing; it only merges
  reads <release dir>/{Packages,Contents}.{published,new} and the debs; writes <repo dir>/Packages
  and <repo dir>/Contents
"""

from __future__ import annotations

import datetime
import functools
import os
import re
import subprocess
import sys
from pathlib import Path

PUBLISHED = "X-Tvb-Published"
KERNEL_RELEASE = re.compile(r"-(\d+\.\d+\S*?-tvb-[\w.+-]+)$")
DEPENDENCY = re.compile(r"^([^\s(]+)(?:\s*\((<<|<=|=|>=|>>)\s*([^)]+)\))?$")


class Stanza:
    def __init__(self, text: str) -> None:
        self.text = text.strip("\n")
        fields = dict(re.findall(r"^([\w-]+): (.*)$", self.text, re.M))
        self.package = fields["Package"]
        self.version = fields["Version"]
        self.filename = Path(fields.get("Filename", "")).name
        self.published = fields.get(PUBLISHED, "")
        self.depends = [d.split("|")[0].strip() for d in fields.get("Depends", "").split(",")]
        release = KERNEL_RELEASE.search(self.package)
        self.release = release.group(1) if release else ""

    def stamped(self, day: str) -> Stanza:
        """This stanza with a publication day, if it has none yet."""
        return self if self.published else Stanza(f"{self.text}\n{PUBLISHED}: {day}")


def parse(text: str) -> list[Stanza]:
    return [Stanza(s) for s in text.split("\n\n") if s.strip()]


def holds(version: str, relation: str, other: str) -> bool:
    return subprocess.run(["dpkg", "--compare-versions", version, relation, other]).returncode == 0


def order(a: Stanza, b: Stanza) -> int:
    if a.version == b.version:
        return 0
    return -1 if holds(a.version, "<<", b.version) else 1


def satisfying(index: list[Stanza], dependency: str) -> list[Stanza]:
    """The stanza a Depends entry needs: the newest of the name its relation allows."""
    match = DEPENDENCY.match(dependency)
    if not match:
        return []
    name, relation, version = match.groups()
    candidates = [s for s in index if s.package == name]
    if relation:
        candidates = [s for s in candidates if holds(s.version, relation, version.strip())]
    return [max(candidates, key=functools.cmp_to_key(order))] if candidates else []


def expire(
    index: list[Stanza],
    today: datetime.date,
    keep_days: int | None,
    shipped: frozenset[str] = frozenset(),
) -> list[Stanza]:
    """The stanzas the repo keeps, each stamped, by package and then version. shipped names the
    debs this run built or reused, which stay whatever their age; keep_days None keeps all."""
    if keep_days is None:
        keep_days = (today - datetime.date.min).days
    cutoff = (today - datetime.timedelta(days=keep_days)).isoformat()
    # a deb copied in again, as a kernel at another's version does, is the published one: its stamp
    unique = {(s.package, s.version): s for s in reversed(index)}
    index = sorted(
        (s.stamped(today.isoformat()) for s in unique.values()), key=functools.cmp_to_key(order)
    )
    kept = {id(s): s for s in index if s.filename in shipped}
    for package in {s.package for s in index if not s.release}:
        versions = [s for s in index if s.package == package]  # oldest first
        kept[id(versions[-1])] = versions[-1]
        for older, newer in zip(versions, versions[1:]):
            if newer.published >= cutoff:  # replaced inside the window
                kept[id(older)] = older
    while True:
        releases = {(s.release, s.version) for s in kept.values() if s.release}
        wanted = [d for s in kept.values() for dep in s.depends for d in satisfying(index, dep)]
        wanted += [s for s in index if (s.release, s.version) in releases]
        grown = {id(s): s for s in wanted if id(s) not in kept}
        if not grown:
            break
        kept.update(grown)
    return sorted(kept.values(), key=lambda s: (s.package, index.index(s)))


def contents(published: str, new: str, rebuilt: set[str], indexed: set[str]) -> str:
    """Every path's owners: the published ones still indexed and not rebuilt, and the new debs'.
    A line is "<path> <owner>,<owner>…", an owner optionally <section>/<package>."""
    owners: dict[str, set[str]] = {}
    for text, carried in ((published, True), (new, False)):
        for line in text.splitlines():
            path, _, names = line.strip().rpartition(" ")
            if not path.strip():
                continue
            held = {n.split("/")[-1] for n in names.split(",")}
            if carried:
                held = {n for n in held if n in indexed and n not in rebuilt}
            if held:
                owners.setdefault(path.strip(), set()).update(held)
    return "".join(f"{path} {','.join(sorted(names))}\n" for path, names in sorted(owners.items()))


def read(path: Path) -> str:
    return path.read_text() if path.is_file() else ""


def main() -> None:
    keep_all = sys.argv[1:2] == ["--keep-all"]
    release, debs, repo = (Path(a) for a in sys.argv[1 + keep_all : 4 + keep_all])
    days = None
    if not keep_all:
        days = os.environ.get("TVB_APT_KEEP_DAYS") or sys.exit(
            "TVB_APT_KEEP_DAYS unset: build.sh sets it"
        )
    new = parse(read(release / "Packages.new"))
    published = parse(read(release / "Packages.published"))
    shipped = frozenset(p.name for p in debs.glob("*.deb"))
    kept = expire(published + new, datetime.date.today(), int(days) if days else None, shipped)
    (repo / "Packages").write_text("\n\n".join(s.text for s in kept) + "\n")
    indexed = {s.package for s in kept}
    old, fresh = read(release / "Contents.published"), read(release / "Contents.new")
    (repo / "Contents").write_text(contents(old, fresh, {s.package for s in new}, indexed))


if __name__ == "__main__":
    main()
