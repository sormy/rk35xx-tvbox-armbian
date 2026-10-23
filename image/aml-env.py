#!/usr/bin/env python3
"""Write an Amlogic vendor U-Boot environment: a factory one, with variables set or replaced.

  aml-env.py <factory-env.bin> <out.bin> name=value ...

The format is U-Boot's non-redundant env: a CRC32 of the rest, then NUL-terminated name=value
pairs and a closing NUL, padded to the env size - the size of the factory file.
"""
import struct
import sys
import zlib


def read_env(path: str) -> tuple[int, dict[bytes, bytes]]:
    raw = open(path, "rb").read()
    if zlib.crc32(raw[4:]) & 0xFFFFFFFF != struct.unpack("<I", raw[:4])[0]:
        sys.exit(f"{path}: the CRC does not match, not an env")
    pairs = (v.split(b"=", 1) for v in raw[4:].split(b"\0") if v)
    return len(raw), {k: v for k, v in pairs}


def write_env(path: str, size: int, env: dict[bytes, bytes]) -> None:
    body = b"".join(k + b"=" + v + b"\0" for k, v in env.items()) + b"\0"
    if len(body) > size - 4:
        sys.exit(f"the env is {len(body)} bytes, past the {size - 4} this U-Boot keeps")
    body = body.ljust(size - 4, b"\0")
    open(path, "wb").write(struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF) + body)


def main() -> None:
    src, dst, *assignments = sys.argv[1:]
    size, env = read_env(src)
    for a in assignments:
        name, value = a.encode().split(b"=", 1)
        env[name] = value
    write_env(dst, size, env)


if __name__ == "__main__":
    main()
