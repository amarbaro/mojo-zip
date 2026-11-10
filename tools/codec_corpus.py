#!/usr/bin/env python3
"""Codec corpus + oracle for src/deflate. `codec_corpus.py DIR` writes DIR/in/*.bin (inputs), DIR/raw/*.raw (streams
made by zlib, for inflate) and DIR/manifest.txt. `codec_corpus.py DIR --verify` compares what tests/codec.mojo wrote
into DIR/out against zlib, live. Deterministic (fixed seeds). Exit 1 on any difference."""
import os
import random
import sys
import zlib

D = sys.argv[1]
R = random.Random(20261110)


def rnd(n):
    return bytes(R.randrange(256) for _ in range(n))


def text(n):
    words = [b"alpha ", b"beta ", b"gamma ", b"delta\n", b"epsilon, ", b"zeta. ", b"the ", b"of ", b"a ", b"mojo ", b"zip "]
    out = bytearray()
    while len(out) < n:
        out += R.choice(words)
    return bytes(out[:n])


def structured(n):
    return bytes((i * 7 + (i >> 8)) & 255 for i in range(n))


def far(n, dist):
    blk = rnd(dist)
    return (blk * (n // dist + 1))[:n]


def mixed(n):
    out = bytearray()
    while len(out) < n:
        k = R.choice((0, 1, 2))
        m = R.randrange(1, 3000)
        out += rnd(m) if k == 0 else (text(m) if k == 1 else bytes([R.randrange(256)]) * m)
    return bytes(out[:n])


def alpha(n, k):
    return bytes(R.randrange(k) + 97 for _ in range(n))


def tiny():
    """60 short inputs over small alphabets: the static/dynamic/stored boundary of block selection."""
    out = {}
    for i in range(60):
        out[f"tiny{i:02d}"] = alpha(R.randrange(1, 90), R.randrange(2, 12))
    return out


INPUTS = {
    "empty": b"", "b1": b"a", "b2": b"ab", "b3": b"abc", "b4": b"aaaa", "hello": b"hello hello hello world ",
    "zeros1k": bytes(1000), "zeros64k": bytes(65536), "zeros100k": bytes(100000), "zeros1m": bytes(1 << 20),
    "ones300": b"\xff" * 300, "period2": b"ab" * 40000, "period3": b"abc" * 30000, "period258": far(70000, 258),
    "period259": far(70000, 259), "far32000": far(200000, 32000), "far32500": far(200000, 32500), "far32768": far(200000, 32768),
    "text10": text(10), "text1k": text(1000), "text33k": text(33000), "text200k": text(200000), "text1500k": text(1500000),
    "rand1": rnd(1), "rand100": rnd(100), "rand1000": rnd(1000), "rand32767": rnd(32767), "rand32768": rnd(32768),
    "rand65535": rnd(65535), "rand65536": rnd(65536), "rand65537": rnd(65537), "rand70000": rnd(70000), "rand300k": rnd(300000),
    "rand1m": rnd(1 << 20), "struct100k": structured(100000), "struct1m": structured(1 << 20), "mixed500k": mixed(500000),
    "mixed2m": mixed(2 << 20), "win98304": text(98304), "win98305": text(98305), "win131072": mixed(131072),
    "alpha4_300k": alpha(300000, 4), "alpha2_100k": alpha(100000, 2), "alpha9_400k": alpha(400000, 9),
    "alltext_nl": b"line\n" * 20000, "bytes256": bytes(range(256)) * 300, "sparse": (bytes(5000) + b"x") * 30,
}
INPUTS.update(tiny())
LEVELS = list(range(10)) + [-1]


def streams(name, data):
    """Python-made raw streams of one input: every level, plus fixed/huffman-only/rle strategies."""
    out = {}
    for lv in (0, 1, 6, 9):
        out[f"{name}.L{lv}"] = zlib.compress(data, lv, wbits=-15)
    for strat, tag in ((zlib.Z_FIXED, "fixed"), (zlib.Z_HUFFMAN_ONLY, "huff"), (zlib.Z_RLE, "rle"), (zlib.Z_FILTERED, "filt")):
        c = zlib.compressobj(6, zlib.DEFLATED, -15, 8, strat)
        out[f"{name}.{tag}"] = c.compress(data) + c.flush()
    return out


def corrupt_set():
    """Truncated and bit-flipped streams of two bases; compared as status classes."""
    base = {"txt": zlib.compress(text(20000), 6, wbits=-15), "mix": zlib.compress(mixed(40000), 9, wbits=-15),
            "fix": (lambda c: c.compress(text(3000)) + c.flush())(zlib.compressobj(6, zlib.DEFLATED, -15, 8, zlib.Z_FIXED)),
            "sto": zlib.compress(rnd(70000), 0, wbits=-15)}
    out = {}
    for k, z in base.items():
        for i in range(1, 12):
            out[f"cut.{k}.{i}"] = z[: len(z) * i // 12]
        out[f"cut.{k}.m1"] = z[:-1]
        out[f"cut.{k}.0"] = b""
        for i in range(40):
            b = bytearray(z)
            b[R.randrange(len(b))] ^= 1 << R.randrange(8)
            out[f"flip.{k}.{i}"] = bytes(b)
        for i in range(10):
            b = bytearray(z)
            b[R.randrange(min(len(b), 60))] ^= 1 << R.randrange(8)
            out[f"head.{k}.{i}"] = bytes(b)
    out["junk.btype3"] = bytes([0x07])
    out["junk.stored_len"] = bytes([0x01, 0x05, 0x00, 0x00, 0x00])
    out["junk.trailing"] = zlib.compress(b"abc", 6, wbits=-15) + b"garbage"
    out["junk.random"] = rnd(300)
    return out


def write():
    for sub in ("in", "raw", "out"):
        os.makedirs(f"{D}/{sub}", exist_ok=True)
    man = []
    for n, d in INPUTS.items():
        open(f"{D}/in/{n}.bin", "wb").write(d)
        man.append(f"deflate {n}")
        for k, z in streams(n, d).items():
            open(f"{D}/raw/{k}.raw", "wb").write(z)
            man.append(f"inflate {k}")
    for k, z in corrupt_set().items():
        open(f"{D}/raw/{k}.raw", "wb").write(z)
        man.append(f"inflate {k}")
    open(f"{D}/manifest.txt", "w").write("\n".join(man) + "\n")


def status_of(z):
    """zlib's verdict on a raw stream: (END|INPUT|BAD, output, unused-bytes)."""
    o = zlib.decompressobj(-15)
    try:
        out = o.decompress(z)
    except zlib.error:
        return "BAD", b"", 0
    return ("END" if o.eof else "INPUT"), out, len(o.unused_data)


def verify():
    bad = 0
    n = 0
    for name, data in INPUTS.items():
        for lv in LEVELS:
            exp = {"o": zlib.compress(data, lv, wbits=-15)}
            if lv in (0, -1, 6):
                c = zlib.compressobj(lv, zlib.DEFLATED, -15)
                exp["s"] = c.compress(data) + c.flush()
            for mode, e in exp.items():
                p = f"{D}/out/{name}.{lv}.{mode}"
                n += 1
                if not os.path.exists(p):
                    print(f"FAIL deflate {name} level {lv} {mode}: no output")
                    bad += 1
                    continue
                got = open(p, "rb").read()
                if got != e:
                    k = next((i for i in range(min(len(got), len(e))) if got[i] != e[i]), min(len(got), len(e)))
                    print(f"FAIL deflate {name} level {lv} {mode}: differs at byte {k} (got {len(got)} bytes, zlib {len(e)})")
                    bad += 1
                try:
                    back = zlib.decompress(got, -15)
                except zlib.error:
                    back = None
                if back != data:
                    print(f"FAIL deflate {name} level {lv} {mode}: zlib does not inflate it back")
                    bad += 1
    for line in open(f"{D}/manifest.txt"):
        op, name = line.split()
        if op != "inflate":
            continue
        z = open(f"{D}/raw/{name}.raw", "rb").read()
        st, out, unused = status_of(z)
        n += 1
        p = f"{D}/out/{name}.inf"
        if not os.path.exists(p):
            print(f"FAIL inflate {name}: no output")
            bad += 1
            continue
        gst, gcrc, glen, gused = open(p).read().split()[:4]
        if st == "BAD":
            ok = gst == "BAD"
        else:
            ok = gst == st and int(glen) == len(out) and int(gcrc) == zlib.crc32(out) and (st != "END" or int(gused) == len(z) - unused)
        if not ok:
            print(f"FAIL inflate {name}: zlib {st} len {len(out)}, got {gst} len {glen}")
            bad += 1
    print(f"codec rows: {n}, failures: {bad}")
    sys.exit(1 if bad else 0)


if "--verify" in sys.argv:
    verify()
else:
    write()
