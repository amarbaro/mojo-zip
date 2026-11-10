"""API checks that are not oracle rows: round trips with random members, read_view, files on disk, the refusal text for
compression types CPython reads through bz2/lzma/zstd, and an archive CPython re-reads (tools/pyread.py)."""
from deflate import crc32, deflate_raw, inflate, inflate_raw, INF_LIMIT
from zipfile import ZipReader, ZipWriter, ZipInfo, make_dt, ZIP_STORED, ZIP_DEFLATED



def lcg_bytes(seed: Int, n: Int, mode: Int) -> List[UInt8]:
    var x = seed * 7919 + 13
    var out = List[UInt8]()
    for i in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        var r = (x >> 16) & 255
        if mode == 0:
            out.append(UInt8(r))
        elif mode == 1:
            out.append(UInt8(97 + r % 6))
        else:
            out.append(UInt8(65 if i % 97 < 90 else r))
    return out^


def same(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def check(ok: Bool, what: String, mut passed: Int, mut total: Int) raises:
    total += 1
    if not ok:
        raise Error("FAIL api: " + what)
    passed += 1


def main() raises:
    var passed = 0
    var total = 0
    # 1. property: random members written at random settings read back equal; the archive is valid for testzip
    var w = ZipWriter(ZIP_DEFLATED, 6)
    var members = List[List[UInt8]]()
    for i in range(60):
        var n = (i * 7919) % 6000 + (i % 5) * 20000 if i % 7 == 0 else (i * 4513) % 3000
        var data = lcg_bytes(i, n, i % 3)
        var level = (i % 11) - 1
        var ct = ZIP_STORED if i % 4 == 0 else ZIP_DEFLATED
        w.writestr("m" + String(i) + "/f.bin", Span(data), ct, level, make_dt(2020, 1 + i % 12, 1 + i % 28, i % 24, i % 60, (i % 30) * 2))
        members.append(data^)
    w.close()
    var archive = w.to_bytes()
    var z = ZipReader.from_bytes(archive.copy())
    check(len(z) == 60, "60 members", passed, total)
    var all_equal = True
    for i in range(60):
        var back = z.read("m" + String(i) + "/f.bin")
        if not same(Span(back), Span(members[i])):
            all_equal = False
    check(all_equal, "random members read back equal", passed, total)
    check(not z.testzip(), "testzip finds nothing", passed, total)
    # 2. read_view: zero copy, stored members only
    var sw = ZipWriter(ZIP_STORED)
    var big = lcg_bytes(5, 100000, 0)
    sw.writestr("big", Span(big))
    sw.writestr("packed", Span(big), ZIP_DEFLATED)
    sw.close()
    var sz = ZipReader.from_bytes(sw.to_bytes())
    var view = sz.read_view("big")
    check(same(view, Span(big)), "read_view equals the data", passed, total)
    var raised = False
    try:
        _ = sz.read_view("packed")
    except e:
        raised = String(e) == "NotImplementedError: read_view needs a STORED member"
    check(raised, "read_view refuses a deflated member", passed, total)
    # 3. a file on disk
    var fw = ZipWriter.create(".work/t/api_file.zip", ZIP_DEFLATED, 9)
    fw.writestr("a.txt", "file round trip, file round trip".as_bytes())
    fw.close()
    var fr = ZipReader.open(".work/t/api_file.zip")
    check(String(unsafe_from_utf8=Span(fr.read("a.txt"))) == "file round trip, file round trip", "file round trip", passed, total)
    # 4. deflate: every level inflates back; level 6 beats stored on text
    var text = lcg_bytes(3, 50000, 1)
    var level_ok = True
    for lv in range(-1, 10):
        if not same(Span(inflate(Span(deflate_raw(Span(text), lv)))), Span(text)):
            level_ok = False
    check(level_ok, "deflate_raw levels -1..9 round trip", passed, total)
    check(len(deflate_raw(Span(text), 6)) < len(text), "level 6 compresses text", passed, total)
    var part = inflate_raw(Span(deflate_raw(Span(text), 6)), 1000)
    check(part.status == INF_LIMIT and len(part.out) == 1000, "inflate_raw stops at max_out", passed, total)
    # 5. types CPython reads through bz2/lzma/zstd are refused with our own text
    for k in range(3):
        var ct = 12 if k == 0 else (14 if k == 1 else 93)
        var aw = ZipWriter(ZIP_STORED)
        var refused = String()
        try:
            aw.writestr("x", "abc".as_bytes(), ct)
        except e:
            refused = String(e)
        var want = "NotImplementedError: compression type " + String(ct) + (" (bzip2)" if ct == 12 else (" (lzma)" if ct == 14 else " (zstd)"))
        check(refused == want, "write refuses compression type " + String(ct), passed, total)
    # 6. archive for CPython: written to disk, re-read by tools/pyread.py
    var pw = ZipWriter.create(".work/t/api_py.zip", ZIP_DEFLATED, 6)
    for i in range(12):
        pw.writestr("n" + String(i) + ".bin", Span(lcg_bytes(100 + i, 1000 * i + 17, i % 3)), ZIP_DEFLATED if i % 2 == 0 else ZIP_STORED, -2, make_dt(2024, 5, 6, 7, 8, 10))
    pw.mkdir("dir")
    pw.close()
    print("PASS api " + String(passed) + "/" + String(total))
