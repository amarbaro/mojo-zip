#!/usr/bin/env python3
"""Live CPython oracle for mojo-zip. Replays tests/golden/vectors.txt rows through zipfile and prints the dump that
tests/cases.mojo prints for the same rows through mojo-zip; scripts/check.sh diffs the two.
Usage: oracle.py --list | oracle.py GROUP WORKDIR | oracle.py --rows FILE   (WORKDIR is unused, kept for the gate's shape)
Row:   read ID HEX [probe=HEXNAME ...]     dump of an archive (every field of every ZipInfo, every member read, testzip)
       write ID TOKENS...                  recipe run through ZipFile; prints the archive bytes then the dump of reading them
Error line contract (docs/plan.md): `<Class>: <args[0]>`; zlib.error -> `error: zlib`; UnicodeDecodeError -> kind only."""
import io
import os
import sys
import warnings
import zipfile
import zlib

warnings.simplefilter("ignore")
sys.unraisablehook = lambda *_: None  # CPython prints a finalizer note after a failed writestr; it is not behaviour
HERE = os.path.dirname(os.path.abspath(__file__))
VECTORS = os.path.join(HERE, "..", "tests", "golden", "vectors.txt")


def errline(e):
    if isinstance(e, zlib.error):
        return "error: zlib"
    if isinstance(e, UnicodeDecodeError):
        return "UnicodeDecodeError"
    n = type(e).__name__
    if isinstance(e, OSError) and e.errno is not None:
        return f"{n}: {e}"
    return n if not e.args else f"{n}: {e.args[0]}"


def hexs(b):
    return bytes(b).hex()


def lcg(seed, n):
    x = seed
    out = bytearray()
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((x >> 16) & 255)
    return bytes(out)


def dataspec(s):
    k, _, rest = s.partition(":")
    if k == "hex":
        return bytes.fromhex(rest)
    if k == "zeros":
        return bytes(int(rest))
    if k == "lcg":
        seed, n = rest.split(":")
        return lcg(int(seed), int(n))
    if k == "text":
        unit = b"The quick brown fox jumps over the lazy dog. "
        n = int(rest)
        return (unit * (n // len(unit) + 1))[:n]
    if k == "pat":
        return bytes((i * 131 + 7) & 255 for i in range(int(rest)))
    raise SystemExit(f"bad data spec {s}")


def dump_read(data, probes=()):
    out = []
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except Exception as e:
        return f"OPEN {errline(e)}\n"
    out.append("OPEN ok")
    out.append(f"COMMENT {hexs(z.comment)}")
    out.append(f"START {z.start_dir}")
    out.append(f"N {len(z.infolist())}")
    for i, x in enumerate(z.infolist()):
        d = x.date_time
        end = -1 if x._end_offset is None else x._end_offset
        out.append(
            f"I {i} {x.orig_filename!r} {x.filename!r} {d[0]}-{d[1]}-{d[2]} {d[3]}:{d[4]}:{d[5]} ct={x.compress_type} "
            f"cv={x.create_version} cs={x.create_system} ev={x.extract_version} rs={x.reserved} fl={x.flag_bits} "
            f"vol={x.volume} ia={x.internal_attr} ea={x.external_attr} off={x.header_offset} crc={x.CRC:08x} "
            f"cz={x.compress_size} fz={x.file_size} end={end} extra={hexs(x.extra)} comment={hexs(x.comment)}")
    out.append("NAMES " + "|".join(repr(n) for n in z.namelist()))
    for x in z.infolist():
        try:
            b = z.read(x.filename)
            out.append(f"R {x.filename!r} {len(b)} {zlib.crc32(b):08x} {zlib.adler32(b):08x}")
        except Exception as e:
            out.append(f"E {x.filename!r} {errline(e)}")
    for p in probes:
        name = bytes.fromhex(p).decode("utf-8")
        try:
            z.getinfo(name)
            out.append(f"G {name!r} ok")
        except Exception as e:
            out.append(f"G {name!r} {errline(e)}")
        try:
            b = z.read(name)
            out.append(f"R {name!r} {len(b)} {zlib.crc32(b):08x} {zlib.adler32(b):08x}")
        except Exception as e:
            out.append(f"E {name!r} {errline(e)}")
    try:
        t = z.testzip()
        out.append("T none" if t is None else f"T {t!r}")
    except Exception as e:
        out.append(f"T {errline(e)}")
    return "\n".join(out) + "\n"


def kv(tok):
    k, _, v = tok.partition("=")
    return k, v


def run_write(tokens):
    """Runs a recipe; returns (archive bytes or None, error line or None)."""
    import zipfile as zf_mod
    ct, level, allow, zl, cl = 0, None, True, None, None
    ops = []
    for t in tokens:
        if t.startswith("new:"):
            for a in t[4:].split(","):
                k, v = kv(a)
                if k == "ct":
                    ct = int(v)
                elif k == "level":
                    level = None if v == "-1" else int(v)
                elif k == "zip64":
                    allow = v == "1"
                elif k == "zlimit":
                    zl = int(v)
                elif k == "climit":
                    cl = int(v)
        else:
            ops.append(t)
    saved = (zf_mod.ZIP64_LIMIT, zf_mod.ZIP_FILECOUNT_LIMIT)
    if zl is not None:
        zf_mod.ZIP64_LIMIT = zl
    if cl is not None:
        zf_mod.ZIP_FILECOUNT_LIMIT = cl
    bio = io.BytesIO()
    err = None
    try:
        z = zipfile.ZipFile(bio, "w", ct, allow, compresslevel=level)
        for op in ops:
            head, _, rest = op.partition(":")
            args = dict(kv(a) for a in rest.split(",")) if rest else {}
            if head == "str":
                name = bytes.fromhex(args["name"]).decode("utf-8")
                dt = tuple(int(x) for x in args["dt"].split("/")) if "dt" in args else (1980, 1, 1, 0, 0, 0)
                zi = zipfile.ZipInfo(name, dt)
                zi.compress_type = z.compression
                zi.compress_level = z.compresslevel
                zi.external_attr = (0o40775 << 16) | 0x10 if name.endswith("/") else 0o600 << 16
                if "ct" in args:
                    zi.compress_type = int(args["ct"])
                if "level" in args:
                    zi.compress_level = None if args["level"] == "-1" else int(args["level"])
                z.writestr(zi, dataspec(args["data"]))
            elif head == "info":
                name = bytes.fromhex(args["name"]).decode("utf-8")
                dt = tuple(int(x) for x in args["dt"].split("/")) if "dt" in args else (1980, 1, 1, 0, 0, 0)
                zi = zipfile.ZipInfo(name, dt)
                zi.compress_type = int(args.get("ct", 0))
                if "level" in args:
                    zi.compress_level = None if args["level"] == "-1" else int(args["level"])
                zi.extra = bytes.fromhex(args.get("extra", ""))
                zi.comment = bytes.fromhex(args.get("comment", ""))
                zi.external_attr = int(args.get("attr", 0))
                zi.create_system = int(args.get("csys", 3))
                zi.internal_attr = int(args.get("iattr", 0))
                zi.flag_bits = int(args.get("flag", 0))
                zi.create_version = int(args.get("cv", 20))
                zi.extract_version = int(args.get("ev", 20))
                zi.reserved = int(args.get("rs", 0))
                z.writestr(zi, dataspec(args["data"]))
            elif head == "mkdir":
                name = bytes.fromhex(args["name"]).decode("utf-8")
                z.mkdir(name, int(args["mode"])) if "mode" in args else z.mkdir(name)
            elif head == "comment":
                v = args["v"]
                z.comment = bytes.fromhex(v[4:]) if v.startswith("hex:") else bytes(int(v[6:]))
            else:
                raise SystemExit(f"bad op {op}")
        z.close()
    except Exception as e:
        err = errline(e)
    finally:
        zf_mod.ZIP64_LIMIT, zf_mod.ZIP_FILECOUNT_LIMIT = saved
    return (None if err else bio.getvalue()), err


def rows(path):
    for line in open(path):
        line = line.rstrip("\n")
        if line and not line.startswith("#"):
            yield line.split(" ")


def replay(rs):
    out = []
    for r in rs:
        op, rid = r[0], r[1]
        out.append(f"== {rid}")
        if op == "read":
            out.append(dump_read(bytes.fromhex(r[2]), [a[6:] for a in r[3:] if a.startswith("probe=")]).rstrip("\n"))
        elif op == "write":
            b, err = run_write(r[2:])
            if err:
                out.append(f"ERR {err}")
            else:
                out.append(f"ARCHIVE {len(b)} {hexs(b)}")
                out.append(dump_read(b).rstrip("\n"))
        else:
            raise SystemExit(f"bad row {r}")
    return "\n".join(out) + "\n"


def groups():
    seen = []
    for r in rows(VECTORS):
        g = r[1].split(".")[0]
        if g not in seen:
            seen.append(g)
    return seen


if __name__ == "__main__":
    if sys.argv[1] == "--list":
        print("\n".join(groups()))
    elif sys.argv[1] == "--rows":
        sys.stdout.write(replay(rows(sys.argv[2])))
    else:
        sys.stdout.write(replay(r for r in rows(VECTORS) if r[1].split(".")[0] == sys.argv[1]))
