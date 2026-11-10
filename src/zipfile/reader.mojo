"""ZipReader: CPython zipfile reading semantics (end record, zip64, prepended data, central directory, member checks,
stored and deflated reads with CRC) over a byte buffer."""
from std.os.path import getsize
from deflate import crc32, inflate_raw, INF_END, INF_BAD
from .text import repr_str, repr_bytes
from .zipinfo import *

comptime _MAX_N = (1 << 31) - 1  # CPython reads and inflates in one call of up to this many bytes


struct _EndRec(Movable):
    var found: Bool
    var disk_number: Int
    var disk_start: Int
    var entries_total: Int
    var size: Int
    var offset: Int
    var location: Int
    var comment: List[UInt8]

    def __init__(out self):
        self.found = False
        self.disk_number = 0
        self.disk_start = 0
        self.entries_total = 0
        self.size = 0
        self.offset = 0
        self.location = 0
        self.comment = List[UInt8]()


def _fill_end(mut r: _EndRec, d: Span[UInt8, _], o: Int):
    r.found = True
    r.disk_number = u16(d, o + 4)
    r.disk_start = u16(d, o + 6)
    r.entries_total = u16(d, o + 10)
    r.size = u32(d, o + 12)
    r.offset = u32(d, o + 16)


def _starts(d: Span[UInt8, _], o: Int, a: Int, b: Int, c: Int, e: Int) -> Bool:
    return o >= 0 and o + 4 <= len(d) and Int(d[o]) == a and Int(d[o + 1]) == b and Int(d[o + 2]) == c and Int(d[o + 3]) == e


def _end_rec_64(d: Span[UInt8, _], location: Int, var r: _EndRec) raises -> _EndRec:
    var offset = location - 20
    if offset < 0:
        return r^
    if not _starts(d, offset, 0x50, 0x4B, 6, 7):
        return r^
    var diskno = u32(d, offset + 4)
    var reloff = u64(d, offset + 8)
    var disks = u32(d, offset + 16)
    if diskno != 0 or disks > 1:
        raise bad_zip("zipfiles that span multiple disks are not supported")
    offset -= 56
    if reloff > offset:
        raise bad_zip("Corrupt zip64 end of central directory locator")
    var extrasz = offset - reloff
    var at = reloff
    if not _starts(d, reloff, 0x50, 0x4B, 6, 6) and reloff != offset:
        at = offset
        extrasz = 0
    if not _starts(d, at, 0x50, 0x4B, 6, 6):
        raise bad_zip("Zip64 end of central directory record not found")
    if at + 56 > len(d):
        r.found = False  # CPython: OSError "Unknown I/O error", reported as not a zip file
        return r^
    var sz = u64(d, at + 4)
    var dircount2 = u64(d, at + 32)
    var dirsize = u64(d, at + 40)
    var diroffset = u64(d, at + 48)
    if diroffset + dirsize != reloff or sz + 12 != 56 + extrasz:
        raise bad_zip("Corrupt zip64 end of central directory record")
    r.disk_number = u32(d, at + 16)
    r.disk_start = u32(d, at + 20)
    r.entries_total = dircount2
    r.size = dirsize
    r.offset = diroffset
    r.location = offset - extrasz
    return r^


def _end_rec_data(d: Span[UInt8, _]) raises -> _EndRec:
    var r = _EndRec()
    var n = len(d)
    if n < 22:
        return r^
    if _starts(d, n - 22, 0x50, 0x4B, 5, 6) and d[n - 2] == 0 and d[n - 1] == 0:
        _fill_end(r, d, n - 22)
        r.location = n - 22
        return _end_rec_64(d, n - 22, r^)
    var wstart = max(n - ZIP_MAX_COMMENT - 22, 0)
    var wend = min(n, wstart + ZIP_MAX_COMMENT + 22)
    var s = -1
    var i = wend - 4
    while i >= wstart:
        if _starts(d, i, 0x50, 0x4B, 5, 6):
            s = i
            break
        i -= 1
    if s < 0 or wend - s < 22:
        return r^
    _fill_end(r, d, s)
    r.comment = List[UInt8](d[s + 22 : min(s + 22 + u16(d, s + 20), wend)])
    r.location = s
    return _end_rec_64(d, s, r^)


def _hash(s: String) -> Int:
    """FNV-1a over the name bytes."""
    var h = UInt64(0xCBF29CE484222325)
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * UInt64(0x100000001B3)
    return Int(h & 0x7FFFFFFFFFFFFFFF)


def _merge_sort_by_offset(mut idx: List[Int], infos: List[ZipInfo]):
    """Stable ascending sort of idx by infos[i].header_offset."""
    var n = len(idx)
    var tmp = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var a = lo
            var b = mid
            var k = lo
            while a < mid and b < hi:
                if infos[idx[b]].header_offset < infos[idx[a]].header_offset:
                    tmp[k] = idx[b]
                    b += 1
                else:
                    tmp[k] = idx[a]
                    a += 1
                k += 1
            while a < mid:
                tmp[k] = idx[a]
                a += 1
                k += 1
            while b < hi:
                tmp[k] = idx[b]
                b += 1
                k += 1
            lo = hi
        for k in range(n):
            idx[k] = tmp[k]
        width *= 2


struct ZipReader(Movable, Sized):
    var data: List[UInt8]
    var infos: List[ZipInfo]
    var comment: List[UInt8]
    var start_dir: Int
    var _slots: List[Int32]  # open-addressing name index: entry number + 1, last duplicate wins

    def __init__(out self, var data: List[UInt8]) raises:
        self.data = data^
        self.infos = List[ZipInfo]()
        self.comment = List[UInt8]()
        self.start_dir = 0
        self._slots = List[Int32]()
        self.start_dir = self._parse()
        self._build_index()

    @staticmethod
    def from_bytes(var data: List[UInt8]) raises -> ZipReader:
        return ZipReader(data^)

    @staticmethod
    def open(path: String) raises -> ZipReader:
        var f = open(path, "r")
        return ZipReader(f.read_bytes(getsize(path)))  # one allocation of the file size, no doubling copies

    def __len__(self) -> Int:
        return len(self.infos)

    def _parse(mut self) raises -> Int:
        var d = Span(self.data)
        var er = _end_rec_data(d)
        if not er.found:
            raise bad_zip("File is not a zip file")
        self.comment = er.comment.copy()
        var concat = er.location - er.size - er.offset
        var start_dir = er.offset + concat
        if start_dir < 0:
            raise bad_zip("Bad offset for central directory")
        var cd = d[min(start_dir, len(d)) : min(start_dir + er.size, len(d))]
        var total = 0
        var p = 0
        var L = len(cd)
        self.infos.reserve(L // 46 + 1)  # one allocation: growing by doubling would peak at 2x the entries
        while total < er.size:
            if L - p < 46:
                raise bad_zip("Truncated central directory")
            if u32(cd, p) != 0x02014B50:
                raise bad_zip("Bad magic number for central directory")
            var flags = u16(cd, p + 8)
            var fnlen = u16(cd, p + 28)
            var exlen = u16(cd, p + 30)
            var cmlen = u16(cd, p + 32)
            var q = p + 46
            var fname = cd[q : min(q + fnlen, L)]
            q += len(fname)
            var extra = cd[q : min(q + exlen, L)]
            q += len(extra)
            var cmt = cd[q : min(q + cmlen, L)]
            q += len(cmt)
            var crc = crc32(fname)
            var x = ZipInfo(decode_name(fname, (flags & MASK_UTF_FILENAME) != 0))
            x.extra = List[UInt8](extra)
            x.comment = List[UInt8](cmt)
            x.header_offset = u32(cd, p + 42)
            x.create_version = Int(cd[p + 4])
            x.create_system = Int(cd[p + 5])
            x.extract_version = Int(cd[p + 6])
            x.reserved = Int(cd[p + 7])
            x.flag_bits = flags
            x.compress_type = u16(cd, p + 10)
            var t = u16(cd, p + 12)
            var dd = u16(cd, p + 14)
            x.CRC = UInt32(u32(cd, p + 16))
            x.compress_size = u32(cd, p + 20)
            x.file_size = u32(cd, p + 24)
            if x.extract_version > MAX_EXTRACT_VERSION:
                raise not_implemented("zip file version " + String(x.extract_version // 10) + "." + String(x.extract_version % 10))
            x.volume = u16(cd, p + 34)
            x.internal_attr = u16(cd, p + 36)
            x.external_attr = u32(cd, p + 38)
            x.date_time = make_dt((dd >> 9) + 1980, (dd >> 5) & 0xF, dd & 0x1F, t >> 11, (t >> 5) & 0x3F, (t & 0x1F) * 2)
            x.decode_extra(crc)
            x.header_offset += concat
            self.infos.append(x^)
            total += 46 + fnlen + exlen + cmlen
            p = q
        var n = len(self.infos)
        var idx = List[Int](length=n, fill=0)
        var sorted_already = True
        for i in range(n):
            idx[i] = i
            if i > 0 and self.infos[i].header_offset < self.infos[i - 1].header_offset:
                sorted_already = False
        if not sorted_already:
            _merge_sort_by_offset(idx, self.infos)
        var end_offset = start_dir
        for k in range(n - 1, -1, -1):
            self.infos[idx[k]]._end_offset = end_offset
            end_offset = self.infos[idx[k]].header_offset
        return start_dir

    def _build_index(mut self):
        var n = len(self.infos)
        var size = 16
        while size < 2 * n:
            size *= 2
        self._slots = List[Int32](length=size, fill=0)
        var mask = size - 1
        for i in range(n):
            var h = _hash(self.infos[i].filename) & mask
            while True:
                var e = Int(self._slots[h])
                if e == 0:
                    self._slots[h] = Int32(i + 1)
                    break
                if self.infos[e - 1].filename == self.infos[i].filename:
                    self._slots[h] = Int32(i + 1)
                    break
                h = (h + 1) & mask

    def _find(self, name: String) -> Int:
        var mask = len(self._slots) - 1
        var h = _hash(name) & mask
        while True:
            var e = Int(self._slots[h])
            if e == 0:
                return -1
            if self.infos[e - 1].filename == name:
                return e - 1
            h = (h + 1) & mask

    def infolist(ref self) -> ref [self.infos] List[ZipInfo]:
        return self.infos

    def namelist(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.infos)):
            out.append(self.infos[i].filename.copy())
        return out^

    def getinfo(self, name: String) raises -> ZipInfo:
        var i = self._find(name)
        if i < 0:
            raise Error("KeyError: There is no item named " + repr_str(name) + " in the archive")
        return self.infos[i].copy()

    def _locate(self, zi: ZipInfo, name: String) raises -> Int:
        """ZipFile.open() checks on a member; returns where its data starts."""
        var d = Span(self.data)
        var h = zi.header_offset
        if h < 0:
            raise Error("ValueError: negative seek value " + String(h))
        if h >= len(d) or len(d) - h < 30:
            raise bad_zip("Truncated file header")
        if u32(d, h) != 0x04034B50:
            raise bad_zip("Bad magic number for file header")
        var lflags = u16(d, h + 6)
        var fnlen = u16(d, h + 26)
        var exlen = u16(d, h + 28)
        var fname = d[min(h + 30, len(d)) : min(h + 30 + fnlen, len(d))]
        var data_start = h + 30 + fnlen + exlen
        if zi.flag_bits & MASK_COMPRESSED_PATCH != 0:
            raise not_implemented("compressed patched data (flag bit 5)")
        if zi.flag_bits & MASK_STRONG_ENCRYPTION != 0:
            raise not_implemented("strong encryption (flag bit 6)")
        var fname_str = decode_name(fname, (lflags & MASK_UTF_FILENAME) != 0)
        if fname_str != zi.orig_filename:
            raise bad_zip("File name in directory " + repr_str(zi.orig_filename) + " and header " + repr_bytes(fname) + " differ.")
        if zi._end_offset >= 0 and data_start + zi.compress_size > zi._end_offset and zi._end_offset != zi.header_offset:
            raise bad_zip("Overlapped entries: " + repr_str(zi.orig_filename) + " (possible zip bomb)")
        if zi.flag_bits & MASK_ENCRYPTED != 0:
            raise Error("RuntimeError: File " + repr_str(name) + " is encrypted, password required for extraction")
        if zi.compress_type != ZIP_STORED and zi.compress_type != ZIP_DEFLATED:
            if zi.compress_type == 12:
                raise not_implemented("compression type 12 (bzip2)")
            if zi.compress_type == 14:
                raise not_implemented("compression type 14 (lzma)")
            if zi.compress_type == 93:
                raise not_implemented("compression type 93 (zstd)")
            raise not_implemented("That compression method is not supported")
        return data_start

    def _crc_check(self, zi: ZipInfo, buf: Span[UInt8, _]) raises:
        if crc32(buf) != zi.CRC:
            raise Error("BadZipFile: Bad CRC-32 for file " + repr_str(zi.filename))

    def read(self, name: String) raises -> List[UInt8]:
        var i = self._find(name)
        if i < 0:
            raise Error("KeyError: There is no item named " + repr_str(name) + " in the archive")
        ref zi = self.infos[i]
        var ds = self._locate(zi, name)
        var d = Span(self.data)
        var C = zi.compress_size
        var F = zi.file_size
        var k = min(C, max(0, len(d) - ds))
        var out = List[UInt8]()
        if C > 0:
            if k == 0:
                raise Error("EOFError")
            if zi.compress_type == ZIP_STORED:
                var take = min(k, F)
                if k < C and take < F:
                    raise Error("EOFError")
                out = List[UInt8](d[ds : ds + take])
            else:
                var r = inflate_raw(d[ds : ds + k], _MAX_N, min(F, k * 1100 + 65536))  # deflate expands at most ~1032:1
                if r.status == INF_BAD:
                    raise Error("error: zlib")
                var eof = r.status == INF_END or k >= C
                if len(r.out) > F:
                    r.out.shrink(F)
                if len(r.out) >= F:
                    eof = True
                if not eof:
                    raise Error("EOFError")
                swap(out, r.out)
        self._crc_check(zi, Span(out))
        return out^

    def read_view(self, name: String) raises -> Span[UInt8, origin_of(self.data)]:
        """The member's bytes without a copy: STORED members only, CRC checked."""
        var i = self._find(name)
        if i < 0:
            raise Error("KeyError: There is no item named " + repr_str(name) + " in the archive")
        ref zi = self.infos[i]
        var ds = self._locate(zi, name)
        if zi.compress_type != ZIP_STORED:
            raise not_implemented("read_view needs a STORED member")
        var k = min(zi.compress_size, max(0, len(self.data) - ds))
        var take = 0
        if zi.compress_size > 0:
            if k == 0 or (k < zi.compress_size and min(k, zi.file_size) < zi.file_size):
                raise Error("EOFError")
            take = min(k, zi.file_size)
        var view = Span(self.data)[ds : ds + take]
        self._crc_check(zi, view)
        return view

    def testzip(self) raises -> Optional[String]:
        """First member (archive order) whose read fails with BadZipFile, else None."""
        for i in range(len(self.infos)):
            try:
                _ = self.read(self.infos[i].filename)
            except e:
                if String(e).startswith("BadZipFile"):
                    return Optional[String](self.infos[i].filename.copy())
                raise e^
        return Optional[String]()
