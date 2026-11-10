"""ZipInfo and the byte-level helpers shared by reader and writer. Behaviour and error texts follow CPython 3.14 zipfile."""
from deflate import crc32
from .text import cp437_decode, cp437_encode, utf8_valid, utf8_string, repr_str

comptime ZIP_STORED = 0
comptime ZIP_DEFLATED = 8
comptime ZIP64_LIMIT = (1 << 31) - 1
comptime ZIP_FILECOUNT_LIMIT = 65535
comptime ZIP_MAX_COMMENT = 65535
comptime DEFAULT_VERSION = 20
comptime ZIP64_VERSION = 45
comptime MAX_EXTRACT_VERSION = 63
comptime MASK_ENCRYPTED = 1
comptime MASK_COMPRESSED_PATCH = 1 << 5
comptime MASK_STRONG_ENCRYPTION = 1 << 6
comptime MASK_UTF_FILENAME = 1 << 11
comptime SAT = 1 << 61  # 64-bit size and offset fields saturate here (known limit)


def bad_zip(msg: String) -> Error:
    return Error("BadZipFile: ", msg)


def not_implemented(msg: String) -> Error:
    return Error("NotImplementedError: ", msg)


def u16(d: Span[UInt8, _], o: Int) -> Int:
    return Int(d[o]) | (Int(d[o + 1]) << 8)


def u32(d: Span[UInt8, _], o: Int) -> Int:
    return Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)


def u64(d: Span[UInt8, _], o: Int) -> Int:
    """Little-endian 64-bit field, saturated at SAT."""
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(d[o + k]) << UInt64(8 * k)
    return SAT if v > UInt64(SAT) else Int(v)


def put16(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))


def put32(mut out: List[UInt8], v: Int):
    put16(out, v & 0xFFFF)
    put16(out, (v >> 16) & 0xFFFF)


def put64(mut out: List[UInt8], v: Int):
    put32(out, v & 0xFFFFFFFF)
    put32(out, (v >> 32) & 0xFFFFFFFF)


def sanitize_filename(s: String) -> String:
    """Terminate the name at the first NUL (POSIX: separators untouched)."""
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == 0:
            return String(unsafe_from_utf8=b[:i])
    return s.copy()


def decode_name(b: Span[UInt8, _], utf8: Bool) raises -> String:
    if utf8:
        if not utf8_valid(b):
            raise Error("UnicodeDecodeError")
        return utf8_string(b)
    return cp437_decode(b)


def make_dt(y: Int = 1980, mo: Int = 1, d: Int = 1, h: Int = 0, mi: Int = 0, s: Int = 0) -> Array[Int, 6]:
    """A date_time value (year, month, day, hour, minute, second)."""
    var a = Array[Int, 6](fill=0)
    a[0] = y
    a[1] = mo
    a[2] = d
    a[3] = h
    a[4] = mi
    a[5] = s
    return a^


struct ZipInfo(Copyable, Movable):
    var orig_filename: String
    var filename: String
    var date_time: Array[Int, 6]
    var compress_type: Int
    var compress_level: Int  # -1 is Python's None / zlib default
    var comment: List[UInt8]
    var extra: List[UInt8]
    var create_system: Int
    var create_version: Int
    var extract_version: Int
    var reserved: Int
    var flag_bits: Int
    var volume: Int
    var internal_attr: Int
    var external_attr: Int
    var header_offset: Int
    var CRC: UInt32
    var compress_size: Int
    var file_size: Int
    var _end_offset: Int  # -1 is Python's None

    def __init__(out self, filename: String = "NoName", date_time: Array[Int, 6] = make_dt()) raises:
        self.orig_filename = filename.copy()
        self.filename = sanitize_filename(filename)
        self.date_time = date_time.copy()
        if date_time[0] < 1980:
            raise Error("ValueError: ZIP does not support timestamps before 1980")
        self.compress_type = ZIP_STORED
        self.compress_level = -1
        self.comment = List[UInt8]()
        self.extra = List[UInt8]()
        self.create_system = 3
        self.create_version = DEFAULT_VERSION
        self.extract_version = DEFAULT_VERSION
        self.reserved = 0
        self.flag_bits = 0
        self.volume = 0
        self.internal_attr = 0
        self.external_attr = 0
        self.header_offset = 0
        self.CRC = 0
        self.compress_size = 0
        self.file_size = 0
        self._end_offset = -1

    def is_dir(self) -> Bool:
        return self.filename.endswith("/")

    def encode_name_flags(self, mut name: List[UInt8]) -> Int:
        """Appends the name as stored (ascii when the UTF-8 flag is set, else cp437, falling back to UTF-8)
        and returns the flag bits to write."""
        if self.flag_bits & MASK_UTF_FILENAME != 0:
            var ascii = True
            for b in self.filename.as_bytes():
                if b >= 128:
                    ascii = False
            if ascii:
                name.extend(self.filename.as_bytes())
                return self.flag_bits & ~MASK_UTF_FILENAME
        elif cp437_encode(self.filename, name):
            return self.flag_bits & ~MASK_UTF_FILENAME
        name.extend(self.filename.as_bytes())
        return self.flag_bits | MASK_UTF_FILENAME

    def file_header(mut self, zip64: Bool) -> List[UInt8]:
        """The local file header (CPython FileHeader); zip64 appends the zip64 extra field and sets version 45."""
        var dt = self.date_time.copy()
        var dosdate = ((dt[0] - 1980) << 9 | dt[1] << 5 | dt[2]) & 0xFFFF
        var dostime = (dt[3] << 11 | dt[4] << 5 | (dt[5] // 2)) & 0xFFFF
        var crc = Int(self.CRC)
        var csize = self.compress_size
        var fsize = self.file_size
        var extra = self.extra.copy()
        var min_version = 0
        if zip64:
            put16(extra, 1)
            put16(extra, 16)
            put64(extra, fsize)
            put64(extra, csize)
            fsize = 0xFFFFFFFF
            csize = 0xFFFFFFFF
            min_version = ZIP64_VERSION
        self.extract_version = max(min_version, self.extract_version)
        self.create_version = max(min_version, self.create_version)
        var name = List[UInt8]()
        var flags = self.encode_name_flags(name)
        var h = List[UInt8]()
        h.append(0x50)
        h.append(0x4B)
        h.append(3)
        h.append(4)
        h.append(UInt8(self.extract_version & 0xFF))
        h.append(UInt8(self.reserved & 0xFF))
        put16(h, flags)
        put16(h, self.compress_type)
        put16(h, dostime)
        put16(h, dosdate)
        put32(h, crc)
        put32(h, csize)
        put32(h, fsize)
        put16(h, len(name))
        put16(h, len(extra))
        h.extend(Span(name))
        h.extend(Span(extra))
        return h^

    def decode_extra(mut self, filename_crc: UInt32) raises:
        """CPython _decodeExtra: zip64 sizes and the unicode path field."""
        var ex = Span(self.extra)
        var pos = 0
        var total = len(ex)
        while total - pos >= 4:
            var tp = u16(ex, pos)
            var ln = u16(ex, pos + 2)
            if ln + 4 > total - pos:
                raise bad_zip("Corrupt extra field " + _hex4(tp) + " (size=" + String(ln) + ")")
            var data = ex[pos + 4 : pos + 4 + ln]
            if tp == 0x0001:
                var off = 0
                var field = String()
                if self.file_size == 0xFFFFFFFF or self.file_size >= SAT:
                    field = "File size"
                    if len(data) - off < 8:
                        raise bad_zip("Corrupt zip64 extra field. " + field + " not found.")
                    self.file_size = u64(data, off)
                    off += 8
                if self.compress_size == 0xFFFFFFFF:
                    field = "Compress size"
                    if len(data) - off < 8:
                        raise bad_zip("Corrupt zip64 extra field. " + field + " not found.")
                    self.compress_size = u64(data, off)
                    off += 8
                if self.header_offset == 0xFFFFFFFF:
                    field = "Header offset"
                    if len(data) - off < 8:
                        raise bad_zip("Corrupt zip64 extra field. " + field + " not found.")
                    self.header_offset = u64(data, off)
            elif tp == 0x7075:
                if len(data) < 5:
                    raise bad_zip("Corrupt unicode path extra field (0x7075)")
                if Int(data[0]) == 1 and UInt32(u32(data, 1)) == filename_crc:
                    var nb = data[5:]
                    if not utf8_valid(nb):
                        raise bad_zip("Corrupt unicode path extra field (0x7075): invalid utf-8 bytes")
                    if len(nb) > 0:
                        self.filename = sanitize_filename(utf8_string(nb))
            pos += ln + 4


def _hex4(v: Int) -> String:
    var digits = "0123456789abcdef"
    var s = String()
    for k in range(3, -1, -1):
        s += String(digits[byte = (v >> (4 * k)) & 15])
    return s^


def extra_strip_zip64(extra: Span[UInt8, _]) -> List[UInt8]:
    """_Extra.strip(extra, (1,)): the extra fields without any zip64 (id 1) field."""
    var out = List[UInt8]()
    var pos = 0
    var n = len(extra)
    while pos < n:
        var xid = -1
        var xlen = 0
        if n - pos >= 4:
            xid = u16(extra, pos)
            xlen = u16(extra, pos + 2)
        var end = min(pos + 4 + xlen, n)
        if xid != 1:
            out.extend(extra[pos:end])
        pos = end
    return out^
