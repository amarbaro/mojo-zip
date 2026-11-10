#!/usr/bin/env python3
"""Time-boxed differential fuzz: mutate archives from tests/golden/vectors.txt (bytes in the end record, the central
directory, local headers, anywhere; truncations; duplicated chunks), replay each through CPython zipfile (tools/oracle.py)
and through mojo-zip (tests/cases.mojo --rows), diff the dumps. Usage: fuzz.py CASES [--seed N] [--rows N] [--budget S]
Prints counts (rows, how many opened, error classes) and the first differences; exit 1 on any difference."""
import collections
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import oracle  # noqa: E402

cases = sys.argv[1]
arg = lambda k, d: int(sys.argv[sys.argv.index(k) + 1]) if k in sys.argv else d
seed, total, budget = arg("--seed", 1), arg("--rows", 4000), arg("--budget", 120)
rng = random.Random(seed)
bases = [bytes.fromhex(r[2]) for r in oracle.rows(oracle.VECTORS) if r[0] == "read" and len(r[2]) < 60000]


def positions(b, sig):
    out, i = [], b.find(sig)
    while i >= 0:
        out.append(i)
        i = b.find(sig, i + 1)
    return out


def mutate(b):
    b = bytearray(b)
    kind = rng.choice(["eocd", "eocd", "cd", "cd", "local", "any", "trunc", "dup", "insert"])
    for _ in range(rng.choice([1, 1, 1, 2, 3])):
        if not b:
            break
        if kind == "eocd":
            lo = max(len(b) - 22 - rng.choice([0, 0, 20, 76]), 0)
            i = rng.randrange(lo, len(b))
        elif kind == "cd" and positions(b, b"PK\1\2"):
            i = rng.choice(positions(b, b"PK\1\2")) + rng.randrange(0, 60)
        elif kind == "local" and positions(b, b"PK\3\4"):
            i = rng.choice(positions(b, b"PK\3\4")) + rng.randrange(0, 40)
        elif kind == "trunc":
            del b[rng.randrange(1, len(b) + 1):]
            break
        elif kind == "dup":
            a = rng.randrange(len(b))
            b[a:a] = b[a:a + rng.randrange(1, 60)]
            break
        elif kind == "insert":
            a = rng.randrange(len(b) + 1)
            b[a:a] = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 12)))
            break
        else:
            i = rng.randrange(len(b))
        i = min(i, len(b) - 1)
        op = rng.choice(["flip", "set", "ff", "zero", "inc", "dec"])
        b[i] = (b[i] ^ (1 << rng.randrange(8))) if op == "flip" else rng.randrange(256) if op == "set" else 255 if op == "ff" else 0 if op == "zero" else (b[i] + 1) & 255 if op == "inc" else (b[i] - 1) & 255
    return bytes(b)


t0 = time.time()
muts = []
while len(muts) < total and time.time() - t0 < budget / 4:
    muts.append(mutate(rng.choice(bases)))
os.makedirs(os.path.join(HERE, "..", ".work", "fuzz"), exist_ok=True)
rowsf = os.path.join(HERE, "..", ".work", "fuzz", f"rows{seed}.txt")
with open(rowsf, "w") as f:
    for i, m in enumerate(muts):
        f.write(f"read fuzz.{i} {m.hex()}\n")
exp = subprocess.run([sys.executable, "-I", os.path.join(HERE, "oracle.py"), "--rows", rowsf], capture_output=True, text=True, timeout=max(budget, 60))
got = subprocess.run([cases, "--rows", rowsf], capture_output=True, text=True, timeout=max(budget, 60))
if exp.returncode or got.returncode:
    print("FAIL fuzz: a side crashed", exp.returncode, got.returncode, exp.stderr[-300:], got.stderr[-300:])
    sys.exit(1)


def blocks(txt):
    d, cur = {}, None
    for ln in txt.split("\n"):
        if ln.startswith("== "):
            cur = ln[3:]
            d[cur] = []
        elif cur:
            d[cur].append(ln)
    return d


import re
be, bg = blocks(exp.stdout), blocks(got.stdout)
# 64-bit fields saturate at 2^61 in mojo-zip (a known limit): rows where CPython shows a 19+ digit number are counted, not diffed
big = [k for k in be if any(re.search(r"\d{19,}", ln) for ln in be[k])]
bad = [k for k in be if be[k] != bg.get(k) and k not in big]
kinds = collections.Counter()
for k in be:
    first = be[k][0] if be[k] else ""
    if first == "OPEN ok":
        kinds["opened"] += 1
        kinds["member errors"] += sum(1 for ln in be[k] if ln.startswith("E "))
    else:
        kinds[first.split(":")[0]] += 1
print(f"fuzz seed {seed}: {len(be)} mutated archives, {len(bad)} differences, {len(big)} skipped for 64-bit saturation; outcomes: {dict(kinds)}")
for k in bad[:5]:
    print(f"DIFF {k}")
    for a, b in zip(be[k], bg.get(k, [])):
        if a != b:
            print("  oracle:", a[:200])
            print("  mojo:  ", b[:200])
            break
sys.exit(1 if bad else 0)
