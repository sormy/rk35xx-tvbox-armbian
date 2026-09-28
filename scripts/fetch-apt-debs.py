#!/usr/bin/env python3
"""Resolve a package closure for an image and download the .debs, so it can install them offline.

  fetch-apt-debs.py --sources DIR --status FILE --out DIR [--kernel VER] [--arch A] PKG...

--sources is the image's /etc/apt/sources.list.d and --status its /var/lib/dpkg/status, so the
closure is exactly what that image is missing, from the repos it already trusts.

The indices are fetched rather than read from the image's own /var/lib/apt/lists. Those lists name
a pool path and a SHA256 for every candidate and look like the obvious source, but a Debian pool
keeps only current versions: an image a few weeks old indexes a libc6-dev that 404s.

--kernel resolves Armbian kernel packages, whose apt version does not identify the kernel they
carry - 26.8.1 is 6.18.43 in the repo and 6.18.44 in the image built from it. The kernel version in
the pool filename is what has to match the installed modules.
"""

import argparse, gzip, hashlib, lzma, os, re, sys, urllib.error, urllib.request


def stanzas(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        block = {}
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                if block:
                    yield block
                block = {}
            elif not line[0].isspace():
                key, _, val = line.partition(":")
                block[key] = val.strip()
        if block:
            yield block


def deb_version_key(v):
    """dpkg's ordering: epoch, then upstream and revision compared part by part."""
    epoch, _, rest = v.partition(":")
    if not rest:
        epoch, rest = "0", v
    upstream, _, revision = rest.rpartition("-")
    if not upstream:
        upstream, revision = rest, ""
    return (int(epoch or 0), _parts(upstream), _parts(revision))


def _parts(s):
    # digits compare numerically, non-digits by dpkg's order where ~ sorts before everything
    order = lambda c: -1 if c == "~" else (ord(c) if c.isalpha() else ord(c) + 256)
    out, i = [], 0
    while i < len(s):
        run = ""
        while i < len(s) and not s[i].isdigit():
            run += s[i]
            i += 1
        out.append((0, [order(c) for c in run]))
        num = ""
        while i < len(s) and s[i].isdigit():
            num += s[i]
            i += 1
        out.append((1, int(num or 0)))
    return out


def index_urls(sources_dir, arch):
    """Every binary index the image's sources declare, as (url, suite)."""
    out = []
    for name in sorted(os.listdir(sources_dir)):
        for block in stanzas(os.path.join(sources_dir, name)):
            if "deb" not in block.get("Types", "deb").split():
                continue
            for uri in block.get("URIs", "").split():
                for suite in block.get("Suites", "").split():
                    for comp in block.get("Components", "").split():
                        out.append((f"{uri.rstrip('/')}/dists/{suite}/{comp}/binary-{arch}/Packages",
                                    uri.rstrip("/"), suite))
    return out


def fetch_index(url):
    errors = []
    for suffix, expand in ((".gz", gzip.decompress), (".xz", lzma.decompress)):
        try:
            with urllib.request.urlopen(url + suffix) as fh:
                return expand(fh.read())
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as err:
            errors.append(f"{suffix}: {err}")
    print(f"  ? {url}: {'; '.join(errors)}", file=sys.stderr)
    return None


def load_lists(sources_dir, arch, cache_dir):
    """name -> [(stanza, base url, suite)], plus a virtual-package map from Provides."""
    pkgs, provides = {}, {}
    os.makedirs(cache_dir, exist_ok=True)
    for url, base, suite in index_urls(sources_dir, arch):
        cached = os.path.join(cache_dir, re.sub(r"\W+", "_", url))
        if not os.path.exists(cached):
            data = fetch_index(url)   # security.debian.org publishes .xz only, the rest .gz
            if data is None:
                continue
            with open(cached, "wb") as fh:
                fh.write(data)
        for block in stanzas(cached):
            if "Package" not in block or "Filename" not in block:
                continue
            pkgs.setdefault(block["Package"], []).append((block, base, suite))
            for virt in re.split(r",\s*", block.get("Provides", "")):
                virt = virt.split()[0] if virt.strip() else ""
                if virt:
                    provides.setdefault(virt, set()).add(block["Package"])
    return pkgs, provides


def installed(status_path):
    return {
        b["Package"]: b.get("Version", "")
        for b in stanzas(status_path)
        if b.get("Status", "").endswith("ok installed")
    }


OPS = {"<<": (-1,), "<=": (-1, 0), "=": (0,), ">=": (0, 1), ">>": (1,)}


def satisfies(version, op, wanted):
    if not op:
        return True
    a, b = deb_version_key(version), deb_version_key(wanted)
    return ((a > b) - (a < b)) in OPS.get(op, (0, 1, -1))


def pick(name, candidates, kernel):
    """What apt would choose: the target release over backports, then the newest version.

    A kernel-stamped Armbian package is chosen by the kernel in its pool filename instead, and a
    miss is fatal - headers for the wrong kernel install cleanly and then fail every DKMS build.
    """
    stamped = [c for c in candidates if "__" in c[0]["Filename"]]
    if stamped and kernel:
        matched = [c for c in stamped if f"__{kernel}-" in c[0]["Filename"]]
        if not matched:
            have = ", ".join(sorted({_stamp(c[0]["Filename"]) for c in stamped}))
            sys.exit(f"{name}: no build for kernel {kernel}; the indices offer {have}")
        candidates = matched
    return max(candidates, key=lambda c: (not c[2].endswith("-backports"),
                                          deb_version_key(c[0]["Version"])))


def _stamp(filename):
    match = re.search(r"__([^-]+)-", filename)
    return match.group(1) if match else "?"


DEP = re.compile(r"^([\w.+-]+)(?::[\w]+)?\s*(?:\(\s*(<<|<=|=|>=|>>)\s*([^)]+?)\s*\))?")


def depends_of(block):
    """[[(name, op, version), ...], ...] - one inner list per comma group, alternatives inside."""
    out = []
    for field in ("Pre-Depends", "Depends"):
        for group in re.split(r",\s*", block.get(field, "")):
            alts = [DEP.match(alt.strip()) for alt in group.split("|") if alt.strip()]
            alts = [(m.group(1), m.group(2), m.group(3)) for m in alts if m]
            if alts:
                out.append(alts)
    return out


def resolve(wanted, pkgs, provides, have, kernel):
    """Breadth-first closure. A dependency the image already satisfies at the required version is
    dropped; one it satisfies only at an older version is pulled in, or the set will not install."""
    chosen, queue, seen = {}, [(n, None, None) for n in wanted], set()
    while queue:
        name, op, version = queue.pop(0)
        if (name, op, version) in seen:
            continue
        seen.add((name, op, version))
        if name in have and satisfies(have[name], op, version):
            continue
        if name in chosen and satisfies(chosen[name][0]["Version"], op, version):
            continue
        if name not in pkgs:
            if name in provides:  # a virtual name: any real package answering it will do
                queue.append((sorted(provides[name])[0], None, None))
            elif name not in have:
                print(f"  ? no candidate for {name}", file=sys.stderr)
            continue
        block, url, _ = pick(name, pkgs[name], kernel)
        chosen[name] = (block, url)
        for alts in depends_of(block):
            if any((dep in have and satisfies(have[dep], dop, dver))
                   or (dep in chosen and satisfies(chosen[dep][0]["Version"], dop, dver))
                   for dep, dop, dver in alts):
                continue
            queue.append(next((a for a in alts if a[0] in pkgs or a[0] in provides), alts[0]))
    return chosen


def download(chosen, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    index, total = [], 0
    for name in sorted(chosen):
        block, url = chosen[name]
        dest = os.path.join(out_dir, os.path.basename(block["Filename"]))
        want = block.get("SHA256", "")
        if not (os.path.exists(dest) and sha256(dest) == want):
            try:
                urllib.request.urlretrieve(f"{url}/{block['Filename']}", dest)
            except urllib.error.HTTPError as err:
                # a pool keeps only current versions, so an index older than the mirror 404s here
                sys.exit(f"{name} {block['Version']}: {err} for {url}/{block['Filename']}")
            if want and sha256(dest) != want:
                sys.exit(f"SHA256 mismatch for {block['Filename']}")
        total += os.path.getsize(dest)
        index.append(dest)
    return index, total


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    for opt in ("sources", "status", "out"):
        ap.add_argument(f"--{opt}", required=True)
    ap.add_argument("--kernel")
    ap.add_argument("--arch", default="arm64")
    ap.add_argument("--index-cache", default=None)
    ap.add_argument("packages", nargs="+")
    args = ap.parse_args()

    cache = args.index_cache or os.path.join(args.out, ".indices")
    pkgs, provides = load_lists(args.sources, args.arch, cache)
    chosen = resolve(args.packages, pkgs, provides, installed(args.status), args.kernel)
    files, total = download(chosen, args.out)
    print(f"{len(files)} packages, {total / 2**20:.1f} MiB -> {args.out}")


if __name__ == "__main__":
    main()
