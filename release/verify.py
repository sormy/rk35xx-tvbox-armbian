#!/usr/bin/env python3
"""Check the published apt repo as a box sees it: the signature, the index against Release, every
deb served at its indexed size, and every Depends on our own packages resolvable in it.

  Usage: release/verify.py [<apt url>]   (default: TVB_APT_URL, or the GitHub release)
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KEYRING = REPO / "keyring/tvb-archive-keyring.gpg"
DEFAULT_URL = "https://github.com/sormy/tvbian/releases/download/apt"
INDEX = ("Packages", "Packages.xz", "Contents")
OURS = re.compile(r"^(tvb-|linux-(image|headers)-.*tvb)")
PINNED = re.compile(r"^([^\s(]+)(?:\s*\(=\s*([^)]+)\))?")
SHA256_LINE = re.compile(r"^ ([0-9a-f]{64}) +(\d+) (\S+)$", re.M)


class Repo:
    def __init__(self, url: str) -> None:
        self.url = url.rstrip("/")
        self.problems: list[str] = []

    def get(self, name: str) -> bytes:
        with urllib.request.urlopen(f"{self.url}/{name}") as response:
            return response.read()

    def served_size(self, name: str) -> int | None:
        request = urllib.request.Request(f"{self.url}/{name}", method="HEAD")
        try:
            with urllib.request.urlopen(request) as response:
                return int(response.headers["Content-Length"])
        except urllib.error.HTTPError:
            return None

    def fail(self, problem: str) -> None:
        self.problems.append(problem)
        print(f"  ✗ {problem}")

    def signed_release(self) -> str:
        inrelease = self.get("InRelease")
        with tempfile.NamedTemporaryFile() as f:
            f.write(inrelease)
            f.flush()
            verified = subprocess.run(
                ["gpgv", "--keyring", str(KEYRING), f.name], capture_output=True
            )
        if verified.returncode:
            self.fail("InRelease is not signed by keyring/tvb-archive-keyring.gpg")
        return inrelease.decode()

    def check_index(self, release: str) -> None:
        hashes = release.split("SHA256:")[1].split("-----BEGIN PGP SIGNATURE")[0]
        listed = {name: (sha, int(size)) for sha, size, name in SHA256_LINE.findall(hashes)}
        for name in INDEX:
            data = self.get(name)
            if name not in listed:
                self.fail(f"{name} is not listed in Release")
            elif (hashlib.sha256(data).hexdigest(), len(data)) != listed[name]:
                self.fail(f"{name} does not match its Release entry")

    def stanzas(self) -> list[dict[str, str]]:
        text = self.get("Packages").decode()
        return [
            dict(re.findall(r"^([\w-]+): (.*)$", s, re.M)) for s in text.split("\n\n") if s.strip()
        ]

    def check_files(self, stanzas: list[dict[str, str]]) -> None:
        for stanza in stanzas:
            name = stanza["Filename"].removeprefix("./")
            served = self.served_size(name)
            if served != int(stanza["Size"]):
                self.fail(f"{name}: indexed at {stanza['Size']} bytes, served {served}")

    def check_depends(self, stanzas: list[dict[str, str]]) -> None:
        """Each Depends on our packages names one here; an exact (= version) pin, that version."""
        versions = {(s["Package"], s["Version"]) for s in stanzas}
        named = {s["Package"] for s in stanzas}
        named |= {
            p.split()[0] for s in stanzas for p in s.get("Provides", "").split(",") if p.strip()
        }
        for stanza in stanzas:
            for clause in stanza.get("Depends", "").split(","):
                match = PINNED.match(clause.split("|")[0].strip())
                if not match or not OURS.match(match.group(1)):
                    continue
                package, pin = match.groups()
                if package not in named or (pin and (package, pin.strip()) not in versions):
                    self.fail(
                        f"{stanza['Package']} {stanza['Version']} depends on {clause.strip()}: not here"
                    )


def main() -> None:
    repo = Repo(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("TVB_APT_URL", DEFAULT_URL))
    repo.check_index(repo.signed_release())
    stanzas = repo.stanzas()
    repo.check_files(stanzas)
    repo.check_depends(stanzas)
    if repo.problems:
        sys.exit(f"✗ {repo.url}: {len(repo.problems)} problem(s)")
    print(
        f"✓ {repo.url}: signed, index matches Release, {len(stanzas)} debs served, Depends resolve"
    )


if __name__ == "__main__":
    main()
