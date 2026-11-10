#!/usr/bin/env python3
"""Reads .work/t/api_py.zip (written by tests/api.mojo) with CPython: testzip, names, every member equal to its recipe."""
import sys
import zipfile

def lcg_bytes(seed, n, mode):
    x = seed * 7919 + 13
    out = bytearray()
    for i in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        r = (x >> 16) & 255
        out.append(r if mode == 0 else 97 + r % 6 if mode == 1 else (65 if i % 97 < 90 else r))
    return bytes(out)

z = zipfile.ZipFile(sys.argv[1] if len(sys.argv) > 1 else ".work/t/api_py.zip")
bad = z.testzip()
if bad is not None:
    print(f"FAIL pyread: testzip names {bad!r}"); sys.exit(1)
for i in range(12):
    info = z.getinfo(f"n{i}.bin")
    if z.read(info) != lcg_bytes(100 + i, 1000 * i + 17, i % 3) or info.date_time != (2024, 5, 6, 7, 8, 10):
        print(f"FAIL pyread: member {i} differs"); sys.exit(1)
if z.getinfo("dir/").external_attr >> 16 != 0o40777 or not z.getinfo("dir/").is_dir():
    print("FAIL pyread: dir entry"); sys.exit(1)
print("PASS pyread: CPython reads the Mojo archive (testzip None, 12 members + dir equal)")
