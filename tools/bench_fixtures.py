#!/usr/bin/env python3
"""Deterministic bench inputs in .work/bench/: many.zip (100k tiny stored members), big_stored.zip (256 MB stored member),
big_deflate.zip (64 MB deflated member). Rebuilt only when missing."""
import sys
import zipfile
from pathlib import Path

D = Path('.work/bench')
D.mkdir(parents=True, exist_ok=True)
DT = (2024, 1, 2, 3, 4, 6)


def zi(name, ct=zipfile.ZIP_STORED):
    z = zipfile.ZipInfo(name, DT)
    z.compress_type = ct  # writestr(ZipInfo) uses the info's type, not the archive's
    z.external_attr = 0o600 << 16
    return z


def pattern(n):
    block = bytes((i * 131 + 7) & 0xFF for i in range(1 << 20))
    return (block * (n >> 20 or 1))[:n]


if not (D / 'many.zip').exists():
    with zipfile.ZipFile(D / 'many.zip', 'w', zipfile.ZIP_STORED) as z:
        for i in range(100_000):
            z.writestr(zi(f'dir{i % 100}/file{i:06d}.txt'), b'x' * (i % 17))
if not (D / 'big_stored.zip').exists():
    with zipfile.ZipFile(D / 'big_stored.zip', 'w', zipfile.ZIP_STORED) as z:
        z.writestr(zi('big.bin'), pattern(256 << 20))
if not (D / 'big_deflate.zip').exists():
    with zipfile.ZipFile(D / 'big_deflate.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(zi('big.bin', zipfile.ZIP_DEFLATED), pattern(64 << 20))
def text(n):
    words = [b'alpha ', b'beta ', b'gamma ', b'delta\n', b'epsilon, ', b'zeta. ', b'the ', b'of ', b'a ', b'mojo ', b'zip ']
    out, x = bytearray(), 12345
    while len(out) < n:
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out += words[(x >> 16) % len(words)]
    return bytes(out[:n])


if not (D / 'big_text.zip').exists():  # realistic dynamic-Huffman inflate: 64 MB of word soup, level 6
    with zipfile.ZipFile(D / 'big_text.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(zi('big.bin', zipfile.ZIP_DEFLATED), text(64 << 20))
print('fixtures ok', file=sys.stderr)
