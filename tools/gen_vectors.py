#!/usr/bin/env python3
"""Writes tests/golden/vectors.txt: crafted archives (read rows) and writer recipes (write rows), deterministic.
Each row id is GROUP.name; groups are the gate's scenarios. See tools/oracle.py for the row grammar."""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "golden", "vectors.txt")
rows = []


def hx(b):
    return bytes(b).hex()


def nm(s):
    return hx(s.encode("utf-8"))


def R(rid, data, probes=()):
    rows.append(f"read {rid} {hx(data)}" + "".join(f" probe={nm(p)}" for p in probes))


def W(rid, *tokens):
    rows.append(f"write {rid} " + " ".join(tokens))


def deflate_raw(b, lv=6):
    c = zlib.compressobj(lv, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


class E:
    """One archive entry; every header field can be overridden to craft a broken archive."""
    def __init__(s, name=b"a.txt", data=b"hello", ct=0, **kw):
        s.name, s.data, s.ct = name, data, ct
        s.__dict__.update(dict(flag=0, ev=20, cv=20, cs=3, rs=0, time=0x6000, date=0x5821, ia=0, ea=0o600 << 16, cmt=b"",
                               extra=b"", lextra=b"", lname=None, lflag=None, crc=None, csize=None, fsize=None, comp=None,
                               hoff=None, cname=None, lct=None, vol=0))
        s.__dict__.update(kw)


def build(entries, comment=b"", pre=b"", cd_extra_size=0, eocd=True, eocd_over=None, tail=b"", cd_junk=b""):
    out = bytearray(pre)
    offs = []
    for e in entries:
        comp = e.comp if e.comp is not None else (deflate_raw(e.data) if e.ct == 8 else e.data)
        crc = e.crc if e.crc is not None else zlib.crc32(e.data)
        cz = e.csize if e.csize is not None else len(comp)
        fz = e.fsize if e.fsize is not None else len(e.data)
        offs.append(len(out))
        ln = e.name if e.lname is None else e.lname
        lf = e.flag if e.lflag is None else e.lflag
        lct = e.ct if e.lct is None else e.lct
        out += struct.pack("<4s2B4HL2L2H", b"PK\3\4", e.ev & 255, e.rs, lf, lct, e.time, e.date, crc, cz & 0xFFFFFFFF, fz & 0xFFFFFFFF, len(ln), len(e.lextra))
        out += ln + e.lextra + comp
    cd_start = len(out) - len(pre)
    cd = bytearray()
    for e, off in zip(entries, offs):
        comp = e.comp if e.comp is not None else (deflate_raw(e.data) if e.ct == 8 else e.data)
        crc = e.crc if e.crc is not None else zlib.crc32(e.data)
        cz = e.csize if e.csize is not None else len(comp)
        fz = e.fsize if e.fsize is not None else len(e.data)
        nmb = e.name if e.cname is None else e.cname
        ho = (off - len(pre)) if e.hoff is None else e.hoff
        cd += struct.pack("<4s4B4HL2L5H2L", b"PK\1\2", e.cv & 255, e.cs, e.ev & 255, e.rs, e.flag, e.ct, e.time, e.date, crc,
                          cz & 0xFFFFFFFF, fz & 0xFFFFFFFF, len(nmb), len(e.extra), len(e.cmt), e.vol, e.ia, e.ea, ho & 0xFFFFFFFF)
        cd += nmb + e.extra + e.cmt
    cd += cd_junk
    out += cd
    if eocd:
        n, sz, of = len(entries), len(cd) + cd_extra_size, cd_start
        if eocd_over:
            n, sz, of = eocd_over.get("n", n), eocd_over.get("size", sz), eocd_over.get("off", of)
        out += struct.pack("<4s4H2LH", b"PK\5\6", 0, 0, n, n, sz, of, len(comment) & 0xFFFF) + comment
    return bytes(out) + tail


def z64(entries_count, cd_size, cd_off, extrasz=0, disk=0, disks=1, reloff=None, sz=None, pre_pos=0, sig=b"PK\6\6", loc_diskno=0):
    """zip64 end record (+ extensible data) and locator; pre_pos = absolute offset where the record will sit."""
    rec = struct.pack("<4sQ2H2L4Q", sig, 44 + extrasz if sz is None else sz, 45, 45, disk, disk, entries_count, entries_count, cd_size, cd_off) + bytes(extrasz)
    loc = struct.pack("<4sLQL", b"PK\6\7", loc_diskno, pre_pos if reloff is None else reloff, disks)
    return rec, loc


def zip64_archive(entries, **kw):
    """A normal archive whose end records are the zip64 pair + a zeroed-count EOCD."""
    base = build(entries, eocd=False)
    cd_size_start = base.rindex(b"PK\1\2") if not entries else None
    # locate the central directory start: sum of local sizes
    off = 0
    for e in entries:
        comp = e.comp if e.comp is not None else (deflate_raw(e.data) if e.ct == 8 else e.data)
        off += 30 + len(e.name if e.lname is None else e.lname) + len(e.lextra) + len(comp)
    cd_size = len(base) - off
    rec, loc = z64(len(entries), kw.get("cd_size", cd_size), kw.get("cd_off", off), kw.get("extrasz", 0), kw.get("disk", 0),
                   kw.get("disks", 1), kw.get("reloff"), kw.get("sz"), len(base), kw.get("sig", b"PK\6\6"), kw.get("loc_diskno", 0))
    eo = struct.pack("<4s4H2LH", b"PK\5\6", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    return base, rec, loc, eo


A = E()
BASE = build([E(b"a.txt", b"hello world"), E(b"b/c.bin", bytes(range(200)) * 3, 8)])

# ---- eocd -------------------------------------------------------------------------------------------------
R("eocd.empty", b"")
R("eocd.short21", bytes(21))
R("eocd.garbage", bytes((i * 37 + 11) & 255 for i in range(300)))
R("eocd.empty_archive", build([]))
R("eocd.basic", BASE)
R("eocd.comment1", build([A], comment=b"x"))
R("eocd.comment_text", build([A], comment=b"an archive comment"))
R("eocd.comment65535", build([A], comment=bytes((i * 7) & 255 for i in range(65535))))
R("eocd.comment65536", build([A], comment=bytes(65536)))
R("eocd.sig_in_comment", build([A], comment=b"PK\5\6" + bytes(18) + b"tail"))
R("eocd.sig_in_comment_short", build([A], comment=b"zz PK\5\6 abc"))
R("eocd.comment_oversized_claim", build([A], comment=b"abc")[:-3] + b"a")
R("eocd.comment_claim_zero_extra", build([A]) + b"trailing junk")
R("eocd.trunc_window", build([A])[:-10])
R("eocd.trunc_in_record", build([A]) + b"")  # placeholder replaced below
rows.pop()
R("eocd.only_sig_at_end", b"PK\5\6" + bytes(10))
R("eocd.cnt_ignored", build([A, E(b"b")], eocd_over={"n": 5}))
R("eocd.cnt_zero", build([A, E(b"b")], eocd_over={"n": 0}))
# ---- zip64 end records ------------------------------------------------------------------------------------
for name, kw in [("ok", {}), ("extensible", {"extrasz": 24}), ("disks2", {"disks": 2}), ("diskno1", {"loc_diskno": 1}),
                 ("reloff_big", {"reloff": 10**6}), ("norecord", {"sig": b"XXXX"}), ("bad_size", {"cd_size": 5}),
                 ("bad_sz", {"sz": 100}), ("bad_off", {"cd_off": 3})]:
    base, rec, loc, eo = zip64_archive([E(b"a.txt", b"hello"), E(b"b", b"xyz")], **kw)
    R(f"zip64.{name}", base + rec + loc + eo)
base, rec, loc, eo = zip64_archive([E(b"a.txt", b"hello")])
R("zip64.prepended", b"JUNKJUNKJUNK" + build([A], eocd=False) + rec + loc + eo)  # offsets not fixed: concat applies
R("zip64.record_displaced", base + b"PADPAD" + rec + loc + eo)  # reloff points before the record: retry at offset path
R("zip64.locator_only_tail", base + loc + eo)
R("zip64.locator_too_early", loc + eo)
R("zip64.tiny", struct.pack("<4s4H2LH", b"PK\5\6", 0, 0, 0, 0, 0, 0, 0))
# ---- prepended data / offsets -----------------------------------------------------------------------------
R("prepend.selfextract", b"MZ" + bytes(100) + BASE)
R("prepend.negative_start", build([A], eocd_over={"size": 10**6}))
R("prepend.offset_wrong_big", build([A], eocd_over={"off": 5000}))
R("prepend.offset_wrong_small", build([A, E(b"b")], pre=b"XX" * 50, eocd_over={"off": 0}))
# ---- central directory ------------------------------------------------------------------------------------
cdb = build([A, E(b"b")])
R("cd.size_too_big", build([A], eocd_over={"size": 5000, "off": len(build([A], eocd=False)) - 46 - 5}))
R("cd.trailing_bytes", build([A], cd_extra_size=10))
R("cd.trailing_45", build([A], cd_extra_size=45))
R("cd.trailing_46", build([A], cd_extra_size=46))
for jn in (1, 45, 46, 47):
    R(f"cd.junk{jn}", build([A], cd_junk=bytes(jn)))
R("cd.junk46_magic", build([A], cd_junk=b"PK\1\2" + bytes(42)))
bad = bytearray(cdb)
i = bad.rindex(b"PK\1\2")
bad[i:i + 4] = b"PK\1\3"
R("cd.bad_magic_second", bytes(bad))
R("cd.no_entries_size0", build([], eocd_over={"n": 3}))
R("cd.truncated_name", build([E(b"abcdefgh")])[: -22 - 5] + struct.pack("<4s4H2LH", b"PK\5\6", 0, 0, 1, 1, 46 + 8 - 5, 30 + 8 + 5, 0))
R("cd.ver63", build([E(ev=63)]))
R("cd.ver64", build([E(ev=64)]))
R("cd.ver255", build([E(ev=255)]))
R("cd.ver64_second", build([A, E(b"b", ev=64)]))
for nm_, (dt_, tm_) in {"min": (0x21, 0), "max": (0xFF9F, 0xBF7D), "bad": ((0 << 9) | (0 << 5) | 0, 0), "month15": ((44 << 9) | (15 << 5) | 1, 0),
                        "day0": ((44 << 9) | (1 << 5) | 0, 0), "h31m63s62": (0x5821, (31 << 11) | (63 << 5) | 31)}.items():
    R(f"cd.date_{nm_}", build([E(date=dt_, time=tm_)]))
R("cd.dup_names", build([E(b"a", b"first"), E(b"b", b"mid"), E(b"a", b"second!")]))
R("cd.offsets_unsorted", build([E(b"a", b"11"), E(b"b", b"22"), E(b"c", b"33")], ))
R("cd.same_offset_twice", build([E(b"a", b"11", hoff=0), E(b"b", b"22", hoff=0)]))
R("cd.attrs", build([E(b"a", ea=0xDEADBEEF, ia=0xFFFF, cs=0, cv=63, rs=7, vol=3, cmt=b"file comment", extra=b"\x99\x99\x02\x00ab")]))
# ---- names ------------------------------------------------------------------------------------------------
R("names.utf8", build([E("héllo/日本.txt".encode(), flag=0x800)]))
R("names.utf8_invalid", build([E(b"bad\xff\xfe.txt", flag=0x800)]))
R("names.utf8_overlong", build([E(b"x\xc0\x80y", flag=0x800)]))
R("names.utf8_surrogate", build([E(b"x\xed\xa0\x80y", flag=0x800)]))
R("names.utf8_4byte", build([E("a😀b".encode(), flag=0x800)]))
R("names.utf8_toohigh", build([E(b"a\xf4\x90\x80\x80b", flag=0x800)]))
R("names.cp437_all", build([E(bytes(range(1, 256)), b"x", cname=None)]))
R("names.cp437_high", build([E(bytes(range(128, 256)), b"x")]))
R("names.nul", build([E(b"abc\x00def", b"x")]))
R("names.nul_first", build([E(b"\x00abc", b"x")]))
R("names.quotes", build([E(b"it's", b"1"), E(b'say "hi"', b"2"), E(b"both ' and \"", b"3"), E(b"back\\slash", b"4"), E(b"tab\tnl\ncr\r", b"5")]),
  probes=["it's", 'say "hi"', "nope", "né", "a\nb"])
R("names.probe_missing", BASE, probes=["missing", "", "a.txt ", "A.TXT"])
R("names.repr_edges", build([E("a\u00a0b\u00adc\u200bd\ue000e\u3000f".encode(), b"1", flag=0x800), E("x\U000d0000y\U0005f600z".encode("utf-8", "surrogatepass"), b"2", flag=0x800), E("é日😀\u0378q".encode(), b"3", flag=0x800)]))
R("names.dir", build([E(b"d/", b""), E(b"d/f", b"1")]))
# ---- extra fields -----------------------------------------------------------------------------------------
def ex(tp, data):
    return struct.pack("<HH", tp, len(data)) + data


R("extra.corrupt_len", build([E(extra=struct.pack("<HH", 0x1234, 50) + b"abc")]))
R("extra.trailing3", build([E(extra=ex(0x1234, b"ok") + b"abc")]))
R("extra.trailing4_len0", build([E(extra=ex(0x1234, b"ok") + struct.pack("<HH", 0x55, 0))]))
R("extra.unknown_ok", build([E(extra=ex(0x1234, b"ok") + ex(0x4321, b"zzzz"))]))
big = 0xFFFFFFFF
R("extra.zip64_all", build([E(b"a", b"hello", csize=big, fsize=big, hoff=big, extra=ex(1, struct.pack("<QQQ", 5, 5, 0)))]))
R("extra.zip64_size_only", build([E(b"a", b"hello", fsize=big, extra=ex(1, struct.pack("<Q", 5)))]))
R("extra.zip64_csize_only", build([E(b"a", b"hello", csize=big, extra=ex(1, struct.pack("<Q", 5)))]))
R("extra.zip64_off_only", build([E(b"a", b"hello", hoff=big, extra=ex(1, struct.pack("<Q", 0)))]))
R("extra.zip64_short_size", build([E(b"a", b"hello", fsize=big, extra=ex(1, b"\0\0\0"))]))
R("extra.zip64_short_csize", build([E(b"a", b"hello", fsize=big, csize=big, extra=ex(1, struct.pack("<Q", 5) + b"\0"))]))
R("extra.zip64_short_off", build([E(b"a", b"hello", fsize=big, csize=big, hoff=big, extra=ex(1, struct.pack("<QQ", 5, 5)))]))
R("extra.zip64_empty_field", build([E(b"a", b"hello", csize=big, extra=ex(1, b""))]))
R("extra.zip64_more_data", build([E(b"a", b"hello", fsize=big, extra=ex(1, struct.pack("<QQQ", 5, 9, 9)))]))
R("extra.zip64_two_fields", build([E(b"a", b"hello", fsize=big, csize=big, extra=ex(1, struct.pack("<Q", 5)) + ex(1, struct.pack("<Q", 5)))]))
R("extra.zip64_not_needed", build([E(b"a", b"hello", extra=ex(1, struct.pack("<QQQ", 9, 9, 9)))]))
R("extra.zip64_u64max", build([E(b"a", b"hello", fsize=big, extra=ex(1, struct.pack("<Q", 5)))]))
crcname = zlib.crc32(b"plain.txt")
R("extra.upath_ok", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 1, crcname) + "ünï.txt".encode()))]))
R("extra.upath_badcrc", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 1, crcname ^ 1) + b"new.txt"))]))
R("extra.upath_version2", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 2, crcname) + b"new.txt"))]))
R("extra.upath_empty", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 1, crcname)))]))
R("extra.upath_short", build([E(b"plain.txt", b"x", extra=ex(0x7075, b"\1\0\0"))]))
R("extra.upath_badutf8", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 1, crcname) + b"\xff\xfe"))]))
R("extra.upath_nul", build([E(b"plain.txt", b"x", extra=ex(0x7075, struct.pack("<BL", 1, crcname) + b"ab\x00cd"))]))
R("extra.upath_dup_target", build([E(b"plain.txt", b"1", extra=ex(0x7075, struct.pack("<BL", 1, crcname) + b"other")), E(b"other", b"2")]))
# ---- open checks ------------------------------------------------------------------------------------------
def with_local(e):
    return build([e])


R("open.trunc_header", build([A])[:20] + build([A])[build([A]).index(b"PK\1\2"):])  # local header cut before CD
b0 = build([A])
cdpos = b0.index(b"PK\1\2")
R("open.header_offset_past_end", build([E(hoff=99999)]))
R("open.local_magic", b"PK\3\5" + b0[4:])
R("open.local_name_differs", build([E(b"a.txt", b"hello", lname=b"b.txt")]))
R("open.local_name_quotes", build([E(b"it's.txt", b"hello", lname=b'q"x\xff')]))
R("open.local_extra", build([E(b"a.txt", b"hello", lextra=b"\1\2\3\4\5\6\7\x08")]))
R("open.local_utf8_flag", build([E("é.txt".encode(), b"hello", flag=0x800, lflag=0)]))
R("open.local_utf8_flag_rev", build([E("é.txt".encode("cp437"), b"hello", flag=0, lflag=0x800)]))
R("open.local_flag_only", build([E(b"a.txt", b"hello", lflag=0x8)]))
R("open.flag5", build([E(flag=0x20)]))
R("open.flag6", build([E(flag=0x40)]))
R("open.flag0_encrypted", build([E(flag=1)]))
R("open.flag5_and_6_and_0", build([E(flag=0x61)]))
R("open.flag_order_name", build([E(flag=0x20, lname=b"zzz")]))
R("open.flag_order_enc_vs_ct", build([E(flag=1, ct=99)]))
R("open.overlap", build([E(b"a", b"x" * 100, csize=200), E(b"b", b"y" * 10)]))
R("open.overlap_same_offset", build([E(b"a", b"hello", hoff=0), E(b"b", b"world", hoff=0)]))
R("open.overlap_last_entry", build([E(b"a", b"x" * 100, csize=100000)]))
R("open.exact_fit", build([E(b"a", b"x" * 100), E(b"b", b"y")]))
# ---- compression types --------------------------------------------------------------------------------------
for ct in (1, 2, 3, 4, 5, 6, 7, 9, 10, 18, 19, 77, 97, 98, 255):
    R(f"ctype.t{ct}", build([E(b"a", b"hello", ct=ct, comp=b"hello")]))
R("ctype.unknown_before_crc", build([E(b"a", b"hello", ct=77, crc=0)]))
# ---- read semantics -----------------------------------------------------------------------------------------
R("read.stored", BASE)
R("read.empty_stored", build([E(b"e", b"")]))
R("read.empty_deflated", build([E(b"e", b"", 8)]))
R("read.empty_bad_crc", build([E(b"e", b"", crc=5)]))
R("read.fsize_zero_with_data", build([E(b"e", b"hello", fsize=0)]))
R("read.fsize_zero_crc0", build([E(b"e", b"hello", fsize=0, crc=0)]))
R("read.fsize_smaller", build([E(b"a", b"hello world", fsize=5, crc=zlib.crc32(b"hello"))]))
R("read.fsize_smaller_badcrc", build([E(b"a", b"hello world", fsize=5)]))
R("read.fsize_larger_stored", build([E(b"a", b"hello", fsize=50)]))
R("read.fsize_larger_stored_crc_ok", build([E(b"a", b"hello", fsize=50)]))
R("read.csize_smaller_stored", build([E(b"a", b"hello world", csize=5, crc=zlib.crc32(b"hello"), fsize=11)]))
R("read.csize_larger_stored", build([E(b"a", b"hello", csize=500), E(b"b", b"x")]))
R("read.csize_zero_stored", build([E(b"a", b"hello", csize=0)]))
R("read.csize_zero_crc0", build([E(b"a", b"hello", csize=0, crc=0)]))
R("read.csize_zero_deflated", build([E(b"a", b"hello", 8, csize=0)]))
R("read.crc_bad", build([E(b"a", b"hello", crc=1)]))
R("read.crc_bad_deflated", build([E(b"a", b"hello" * 100, 8, crc=1)]))
R("read.deflated", build([E(b"t", b"abc" * 5000, 8), E(b"r", bytes((i * 7919) & 255 for i in range(3000)), 8)]))
R("read.deflated_fsize_smaller", build([E(b"t", b"abc" * 100, 8, fsize=10)]))
R("read.deflated_fsize_smaller_crc", build([E(b"t", b"abc" * 100, 8, fsize=10, crc=zlib.crc32(b"abc" * 100)[:0] if False else zlib.crc32((b"abc" * 100)[:10]))]))
R("read.deflated_fsize_larger", build([E(b"t", b"abc" * 100, 8, fsize=1000)]))
R("read.deflated_fsize_larger_crc", build([E(b"t", b"abc" * 100, 8, fsize=1000)]))
z = deflate_raw(b"abc" * 5000)
R("read.deflated_trailing_garbage_in_csize", build([E(b"t", b"abc" * 5000, 8, comp=z + b"GARBAGE")]))
R("read.deflated_truncated_stream", build([E(b"t", b"abc" * 5000, 8, comp=z[: len(z) // 2])]))
R("read.deflated_truncated_stream_crc_ok", build([E(b"t", b"abc" * 5000, 8, comp=z[: len(z) // 2], crc=zlib.crc32(b""), fsize=0)]))
R("read.deflated_corrupt", build([E(b"t", b"abc" * 5000, 8, comp=bytes([z[0] ^ 0xFF]) + z[1:])]))
R("read.deflated_corrupt_mid", build([E(b"t", b"abc" * 5000, 8, comp=z[:5] + bytes([z[5] ^ 0x55]) + z[6:])]))
R("read.deflated_junk", build([E(b"t", b"abc" * 5000, 8, comp=bytes(range(200)))]))
R("read.deflated_stream_has_more", build([E(b"t", b"abc" * 5000, 8, comp=deflate_raw(b"abc" * 5000 + b"extra data beyond"), fsize=15000)]))
R("read.stored_as_deflate_type", build([E(b"t", b"plain text here", 8, comp=b"plain text here")]))
R("read.dd_flag", build([E(b"a", b"hello", flag=0x8, lflag=0x8, csize=5), E(b"b", b"x" * 40, 8, flag=0x8, lflag=0x8)]))
bt = build([E(b"a", b"x" * 1000)])
R("read.file_truncated_data", bt[:200] + bt[bt.index(b"PK\1\2"):])
R("read.file_truncated_data_deflated", build([E(b"a", b"xyz" * 4000, 8)])[:50] + build([E(b"a", b"xyz" * 4000, 8)])[build([E(b"a", b"xyz" * 4000, 8)]).index(b"PK\1\2"):])
R("read.big_stored", build([E(b"big", bytes((i * 131 + 7) & 255 for i in range(70000)))]))
R("read.big_deflated", build([E(b"big", bytes((i * 131 + 7) & 255 for i in range(70000)), 8)]))
R("read.ratio_deflated", build([E(b"z", bytes(300000), 8)]))
R("read.testzip_second_bad", build([E(b"a", b"ok"), E(b"b", b"bad", crc=3), E(b"c", b"fine")]))
R("read.testzip_dup_last_bad", build([E(b"a", b"ok"), E(b"a", b"bad", crc=3)]))
R("read.testzip_dup_first_bad", build([E(b"a", b"bad", crc=3), E(b"a", b"ok")]))
R("read.testzip_zlib_error", build([E(b"a", b"x" * 100, 8, comp=bytes(range(50))), E(b"b", b"y", crc=1)]))
R("read.testzip_eof", build([E(b"a", b"x" * 1000)])[:100] + build([E(b"a", b"x" * 1000)])[build([E(b"a", b"x" * 1000)]).index(b"PK\1\2"):])
# ---- writer -------------------------------------------------------------------------------------------------
n_ = nm
D = "data=text:300"
W("writer.stored_basic", "new:ct=0", f"str:name={n_('a.txt')},{D}")
for lv in (-1, 0, 1, 6, 9):
    W(f"writer.deflate_l{lv}", f"new:ct=8,level={lv}", f"str:name={n_('a.txt')},{D}", f"str:name={n_('r.bin')},data=lcg:5:1000")
W("writer.deflate_levels_per_call", "new:ct=8,level=9", f"str:name={n_('x')},{D},level=1", f"str:name={n_('y')},{D},level=0", f"str:name={n_('z')},{D},ct=0")
W("writer.level_invalid", "new:ct=8,level=10", f"str:name={n_('a')},{D}")
W("writer.level_invalid_call", "new:ct=8", f"str:name={n_('a')},{D},level=11")
W("writer.level_ignored_stored", "new:ct=0,level=99", f"str:name={n_('a')},{D}")
W("writer.empty_deflate", "new:ct=8", f"str:name={n_('e')},data=hex:")
W("writer.empty_stored", "new:ct=0", f"str:name={n_('e')},data=hex:")
W("writer.one_byte", "new:ct=8", f"str:name={n_('e')},data=hex:41")
for sz in (65535, 65536, 65537):
    W(f"writer.size_{sz}", "new:ct=8", f"str:name={n_('r')},data=lcg:9:{sz}", f"str:name={n_('t')},data=text:{sz}")
W("writer.incompressible_bigger", "new:ct=8,level=9", f"str:name={n_('r')},data=lcg:3:5000")
W("writer.zeros", "new:ct=8", f"str:name={n_('z')},data=zeros:100000")
W("writer.names_nonascii", "new:ct=8", f"str:name={n_('é.txt')},{D}", f"str:name={n_('日本/語.txt')},{D}", f"str:name={n_('a😀')},data=hex:01")
W("writer.mkdir_names", "new:ct=0", f"mkdir:name={n_('d')}", f"mkdir:name={n_('é/')}", f"mkdir:name={n_('日本')}", f"mkdir:name={n_('m')},mode=493")
W("writer.dir_via_str", "new:ct=8", f"str:name={n_('d/')},data=hex:", f"str:name={n_('d/f')},{D}")
W("writer.dt_edges", "new:ct=0", f"str:name={n_('a')},data=hex:61,dt=2107/12/31/23/59/58", f"str:name={n_('b')},data=hex:62,dt=1980/1/1/0/0/1", f"str:name={n_('c')},data=hex:63,dt=2024/2/29/12/30/59")
W("writer.dt_before_1980", "new:ct=0", f"str:name={n_('a')},data=hex:61,dt=1979/1/1/0/0/0")
W("writer.info_fields", "new:ct=0", f"info:name={n_('a')},{D},ct=8,extra={hx(b'ab' + b'cd')},comment={hx(b'note')},attr=33188,csys=0,iattr=1,cv=63,ev=45,rs=1")
W("writer.info_flag_overwritten", "new:ct=0", f"info:name={n_('a')},{D},flag=8")
W("writer.info_attr_default", "new:ct=0", f"info:name={n_('a')},{D}")
W("writer.info_extra_zip64_user", "new:ct=0,zlimit=100", f"info:name={n_('a')},data=zeros:120,extra={hx(ex(1, bytes(24)) + ex(0x77, b'ab'))}")
W("writer.archive_comment", "new:ct=0", "comment:v=hex:" + hx(b"an archive comment"), f"str:name={n_('a')},{D}")
W("writer.archive_comment_long", "new:ct=0", "comment:v=zeros:70000", f"str:name={n_('a')},{D}")
W("writer.archive_comment_max", "new:ct=0", "comment:v=zeros:65535")
W("writer.empty_archive", "new:ct=0")
W("writer.duplicates", "new:ct=0", f"str:name={n_('a')},data=hex:01", f"str:name={n_('a')},data=hex:02")
W("writer.ctype_77", "new:ct=0", f"str:name={n_('a')},{D},ct=77")
W("writer.ctype_1", "new:ct=0", f"str:name={n_('a')},{D},ct=1")
W("writer.info_ctype_9", "new:ct=0", f"info:name={n_('a')},{D},ct=9")
W("writer.mixed", "new:ct=8,level=6", f"str:name={n_('a')},{D}", f"mkdir:name={n_('d')}", f"str:name={n_('d/b')},data=lcg:2:200,ct=0", f"str:name={n_('d/c')},data=text:5000,level=1")
# ---- zip64 writing (module limits lowered like CPython's tests) ------------------------------------------------
W("zip64w.file_size_over", "new:ct=0,zlimit=100", f"str:name={n_('a')},data=zeros:120", f"str:name={n_('b')},data=zeros:5")
W("zip64w.file_size_over_deflated", "new:ct=8,zlimit=100", f"str:name={n_('a')},data=zeros:5000", f"str:name={n_('b')},data=zeros:5")
W("zip64w.csize_over_only", "new:ct=8,zlimit=100", f"str:name={n_('a')},data=lcg:4:90")
W("zip64w.offset_over", "new:ct=0,zlimit=200", f"str:name={n_('a')},data=zeros:150", f"str:name={n_('b')},data=zeros:20", f"str:name={n_('c')},data=zeros:5")
W("zip64w.all_three", "new:ct=0,zlimit=100", f"str:name={n_('a')},data=zeros:120", f"str:name={n_('b')},data=zeros:120", f"str:name={n_('c')},data=zeros:5")
W("zip64w.count_over", "new:ct=0,climit=3", *[f"str:name={n_('f%d' % i)},data=hex:41" for i in range(5)])
W("zip64w.count_equal", "new:ct=0,climit=3", *[f"str:name={n_('f%d' % i)},data=hex:41" for i in range(3)])
W("zip64w.cd_offset_over", "new:ct=0,zlimit=100", f"str:name={n_('a')},data=zeros:60")
W("zip64w.cd_size_over", "new:ct=0,zlimit=150", *[f"str:name={n_('f%d' % i)},data=hex:41" for i in range(4)])
W("zip64w.no64_filesize", "new:ct=0,zip64=0,zlimit=100", f"str:name={n_('a')},data=zeros:120")
W("zip64w.no64_filesize_margin", "new:ct=0,zip64=0,zlimit=100", f"str:name={n_('a')},data=zeros:96")
W("zip64w.no64_count", "new:ct=0,zip64=0,climit=2", *[f"str:name={n_('f%d' % i)},data=hex:41" for i in range(3)])
W("zip64w.no64_offset", "new:ct=0,zip64=0,zlimit=100", f"str:name={n_('a')},data=zeros:80", f"str:name={n_('b')},data=zeros:5")
W("zip64w.no64_cd_offset", "new:ct=0,zip64=0,zlimit=100", f"str:name={n_('a')},data=zeros:60")
W("zip64w.no64_cd_count", "new:ct=0,zip64=0,climit=1", f"str:name={n_('a')},data=hex:41", f"mkdir:name={n_('d')}")
W("zip64w.no64_csize", "new:ct=8,zip64=0,zlimit=100", f"str:name={n_('a')},data=lcg:4:90")
W("zip64w.comp_too_large", "new:ct=8,zlimit=100", f"str:name={n_('a')},data=lcg:7:50", f"str:name={n_('b')},data=lcg:8:89")
W("zip64w.mkdir_over", "new:ct=0,zlimit=40", f"mkdir:name={n_('a')}", f"mkdir:name={n_('b')}")
W("zip64w.mkdir_no64", "new:ct=0,zip64=0,zlimit=40", f"mkdir:name={n_('a')}", f"mkdir:name={n_('b')}")

open(OUT, "w").write("# generated by tools/gen_vectors.py; do not edit\n" + "\n".join(rows) + "\n")
print(f"{len(rows)} rows")
