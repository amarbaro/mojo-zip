#!/usr/bin/env python3
"""CPython reference for bench/zipbench.mojo: the same jobs on the same fixtures. Usage: bench_ref.py [many|stored|deflate|text|compress]"""
import io
import sys
import time
import zipfile
import zlib

which = sys.argv[1] if len(sys.argv) > 1 else 'many'
t0 = time.perf_counter_ns()
if which == 'many':
    z = zipfile.ZipFile('.work/bench/many.zip')
    total = sum(i.file_size for i in z.infolist())
    n = len(z.namelist())
    check = f'entries {n} bytes {total}'
elif which == 'compress':
    words = [b'alpha ', b'beta ', b'gamma ', b'delta\n', b'epsilon, ', b'zeta. ', b'the ', b'of ', b'a ', b'mojo ', b'zip ']
    buf, x = bytearray(), 12345
    while len(buf) < 16 << 20:
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        buf += words[(x >> 16) % len(words)]
    data = bytes(buf[:16 << 20])
    t0 = time.perf_counter_ns()
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr('t', data)
    check = f'bytes {len(out.getvalue())}'
else:
    z = zipfile.ZipFile(f'.work/bench/big_{which}.zip')
    data = z.read('big.bin')
    check = f'bytes {len(data)} crc {zlib.crc32(data):08x}'
t1 = time.perf_counter_ns()
print(f'python {which} ms {(t1 - t0) // 1_000_000} {check}')
