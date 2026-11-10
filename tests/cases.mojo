"""Case runner: replays tests/golden/vectors.txt rows (or any rows file) through mojo-zip and prints the same dump
tools/oracle.py prints through CPython zipfile. Usage: cases GROUP WORKDIR | cases --rows FILE"""
from std.sys import argv
from deflate import crc32
from zipfile import ZipReader, ZipWriter, ZipInfo, make_dt, ZIP_STORED, ZIP_DEFLATED
from zipfile.text import repr_str


def hexs(b: Span[UInt8, _]) -> String:
    var digits = "0123456789abcdef"
    var s = String()
    for i in range(len(b)):
        s += String(digits[byte = Int(b[i]) >> 4])
        s += String(digits[byte = Int(b[i]) & 15])
    return s^


def hex8(v: UInt32) -> String:
    var digits = "0123456789abcdef"
    var s = String()
    for k in range(7, -1, -1):
        s += String(digits[byte = Int((v >> UInt32(4 * k)) & 15)])
    return s^


def unhex(s: StringSlice) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i + 1 < len(b):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        out.append(UInt8(((hi - 48) if hi < 58 else (hi - 87)) * 16 + ((lo - 48) if lo < 58 else (lo - 87))))
        i += 2
    return out^


def adler32(d: Span[UInt8, _]) -> UInt32:
    var a = UInt32(1)
    var b = UInt32(0)
    for i in range(len(d)):
        a = (a + UInt32(d[i])) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


def toint(s: StringSlice) -> Int:
    try:
        return Int(String(s))
    except:
        return 0


def lcg(seed: Int, n: Int) -> List[UInt8]:
    var x = seed
    var out = List[UInt8]()
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(UInt8((x >> 16) & 255))
    return out^


def dataspec(spec: StringSlice) -> List[UInt8]:
    var parts = spec.split(":")
    var k = String(parts[0])
    if k == "hex":
        return unhex(parts[1]) if len(parts) > 1 else List[UInt8]()
    if k == "zeros":
        return List[UInt8](length=toint(parts[1]), fill=0)
    if k == "lcg":
        return lcg(toint(parts[1]), toint(parts[2]))
    if k == "text":
        var unit = String("The quick brown fox jumps over the lazy dog. ").as_bytes()
        var n = toint(parts[1])
        var out = List[UInt8]()
        for i in range(n):
            out.append(unit[i % len(unit)])
        return out^
    var n = toint(parts[1])  # pat
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 131 + 7) & 255))
    return out^


def dump_read(data: List[UInt8], probes: List[String]) -> String:
    var out = String()
    var z: ZipReader
    try:
        z = ZipReader.from_bytes(data.copy())
    except e:
        return "OPEN " + String(e) + "\n"
    out += "OPEN ok\n"
    out += "COMMENT " + hexs(Span(z.comment)) + "\n"
    out += "START " + String(z.start_dir) + "\n"
    out += "N " + String(len(z.infos)) + "\n"
    for i in range(len(z.infos)):
        ref x = z.infos[i]
        out += "I " + String(i) + " " + repr_str(x.orig_filename) + " " + repr_str(x.filename) + " "
        out += String(x.date_time[0]) + "-" + String(x.date_time[1]) + "-" + String(x.date_time[2]) + " "
        out += String(x.date_time[3]) + ":" + String(x.date_time[4]) + ":" + String(x.date_time[5])
        out += " ct=" + String(x.compress_type) + " cv=" + String(x.create_version) + " cs=" + String(x.create_system)
        out += " ev=" + String(x.extract_version) + " rs=" + String(x.reserved) + " fl=" + String(x.flag_bits)
        out += " vol=" + String(x.volume) + " ia=" + String(x.internal_attr) + " ea=" + String(x.external_attr)
        out += " off=" + String(x.header_offset) + " crc=" + hex8(x.CRC) + " cz=" + String(x.compress_size)
        out += " fz=" + String(x.file_size) + " end=" + String(x._end_offset)
        out += " extra=" + hexs(Span(x.extra)) + " comment=" + hexs(Span(x.comment)) + "\n"
    out += "NAMES "
    for i in range(len(z.infos)):
        if i > 0:
            out += "|"
        out += repr_str(z.infos[i].filename)
    out += "\n"
    for i in range(len(z.infos)):
        out += read_line(z, z.infos[i].filename)
    for p in probes:
        var name = String(unsafe_from_utf8=Span(unhex(p)))
        try:
            _ = z.getinfo(name)
            out += "G " + repr_str(name) + " ok\n"
        except e:
            out += "G " + repr_str(name) + " " + String(e) + "\n"
        out += read_line(z, name)
    try:
        var t = z.testzip()
        out += "T none\n" if not t else "T " + repr_str(t.value()) + "\n"
    except e:
        out += "T " + String(e) + "\n"
    return out^


def read_line(z: ZipReader, name: String) -> String:
    try:
        var b = z.read(name)
        return "R " + repr_str(name) + " " + String(len(b)) + " " + hex8(crc32(Span(b))) + " " + hex8(adler32(Span(b))) + "\n"
    except e:
        return "E " + repr_str(name) + " " + String(e) + "\n"


def kvs(rest: StringSlice) -> Dict[String, String]:
    var d = Dict[String, String]()
    if rest.byte_length() == 0:
        return d^
    for a in rest.split(","):
        var s = String(a)
        var eq = s.find("=")
        d[String(s[byte = 0 : eq])] = String(s[byte = eq + 1 :])
    return d^


def dt_of(s: String) -> Array[Int, 6]:
    var parts = s.split("/")
    return make_dt(toint(parts[0]), toint(parts[1]), toint(parts[2]), toint(parts[3]), toint(parts[4]), toint(parts[5]))


def run_write(tokens: List[String]) -> String:
    var ct = 0
    var level = -1
    var allow = True
    var zl = -1
    var cl = -1
    var ops = List[String]()
    for t in tokens:
        if t.startswith("new:"):
            for a in String(t[byte = 4 :]).split(","):
                var s = String(a)
                var eq = s.find("=")
                var k = String(s[byte = 0 : eq])
                var v = String(s[byte = eq + 1 :])
                if k == "ct":
                    ct = toint(v)
                elif k == "level":
                    level = toint(v)
                elif k == "zip64":
                    allow = v == "1"
                elif k == "zlimit":
                    zl = toint(v)
                elif k == "climit":
                    cl = toint(v)
        else:
            ops.append(t.copy())
    var w = ZipWriter(ct, level, allow)
    if zl >= 0:
        w.zip64_limit = zl
    if cl >= 0:
        w.filecount_limit = cl
    try:
        for op in ops:
            var colon = op.find(":")
            var head = String(op[byte = 0 : colon])
            var a = kvs(String(op[byte = colon + 1 :]))
            if head == "str":
                var name = String(unsafe_from_utf8=Span(unhex(a.get("name", String()))))
                var dt = dt_of(a.get("dt", String())) if "dt" in a else make_dt()
                var ctv = toint(a.get("ct", String())) if "ct" in a else -1
                var lv = toint(a.get("level", String())) if "level" in a else -2
                w.writestr(name, Span(dataspec(a.get("data", String()))), ctv, lv, dt)
            elif head == "info":
                var name = String(unsafe_from_utf8=Span(unhex(a.get("name", String()))))
                var zi = ZipInfo(name, dt_of(a.get("dt", String())) if "dt" in a else make_dt())
                zi.compress_type = toint(a.get("ct", String())) if "ct" in a else 0
                if "level" in a:
                    zi.compress_level = toint(a.get("level", String()))
                zi.extra = unhex(a.get("extra", String())) if "extra" in a else List[UInt8]()
                zi.comment = unhex(a.get("comment", String())) if "comment" in a else List[UInt8]()
                zi.external_attr = toint(a.get("attr", String())) if "attr" in a else 0
                zi.create_system = toint(a.get("csys", String())) if "csys" in a else 3
                zi.internal_attr = toint(a.get("iattr", String())) if "iattr" in a else 0
                zi.flag_bits = toint(a.get("flag", String())) if "flag" in a else 0
                zi.create_version = toint(a.get("cv", String())) if "cv" in a else 20
                zi.extract_version = toint(a.get("ev", String())) if "ev" in a else 20
                zi.reserved = toint(a.get("rs", String())) if "rs" in a else 0
                w.writestr(zi^, Span(dataspec(a.get("data", String()))))
            elif head == "mkdir":
                var name = String(unsafe_from_utf8=Span(unhex(a.get("name", String()))))
                w.mkdir(name, toint(a.get("mode", String())) if "mode" in a else 511)
            elif head == "comment":
                var v = a.get("v", String())
                if v.startswith("hex:"):
                    w.set_comment(Span(unhex(String(v[byte = 4 :]))))
                else:
                    w.set_comment(Span(List[UInt8](length=toint(String(v[byte = 6 :])), fill=0)))
        w.close()
        var b = w.to_bytes()
        return "ARCHIVE " + String(len(b)) + " " + hexs(Span(b)) + "\n" + dump_read(b, List[String]())
    except e:
        return "ERR " + String(e) + "\n"


def replay(lines: List[String], group: String) raises:
    for ln in lines:
        if ln.byte_length() == 0 or ln.startswith("#"):
            continue
        var r = ln.split(" ")
        var rid = String(r[1])
        if group.byte_length() > 0 and String(rid.split(".")[0]) != group:
            continue
        print("== " + rid)
        if String(r[0]) == "read":
            var probes = List[String]()
            for k in range(3, len(r)):
                if r[k].startswith("probe="):
                    probes.append(String(r[k][byte = 6 :]))
            print(dump_read(unhex(r[2]), probes).rstrip("\n"))
        else:
            var tokens = List[String]()
            for k in range(2, len(r)):
                tokens.append(String(r[k]))
            print(run_write(tokens).rstrip("\n"))


def main() raises:
    var args = argv()
    var path = String("tests/golden/vectors.txt")
    var group = String()
    if String(args[1]) == "--rows":
        path = String(args[2])
    else:
        group = String(args[1])
    var text = open(path, "r").read()
    var lines = List[String]()
    for ln in text.split("\n"):
        lines.append(String(ln))
    replay(lines, group)
