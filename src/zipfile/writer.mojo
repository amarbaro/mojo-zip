"""ZipWriter: CPython ZipFile.writestr / mkdir / close byte for byte (local headers, zip64 fields, central directory,
end records), with the pure-Mojo deflate. Members are compressed one at a time and flushed to the file per member."""
from std.os import getenv
from deflate import crc32, deflate_raw
from .text import repr_str
from .zipinfo import *


def _large(what: String) -> Error:
    return Error("LargeZipFile: ", what, " would require ZIP64 extensions")


def _gmtime(epoch: Int) -> Array[Int, 6]:
    """time.gmtime(epoch)[:6] (proleptic Gregorian, UTC)."""
    var days = epoch // 86400
    var rem = epoch - days * 86400
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return make_dt(y, m, d, rem // 3600, (rem % 3600) // 60, rem % 60)


struct ZipWriter(Movable):
    var compression: Int
    var compresslevel: Int
    var allow_zip64: Bool
    var zip64_limit: Int  # the real constants by default; tests lower them like CPython's monkeypatching
    var filecount_limit: Int
    var infos: List[ZipInfo]
    var comment: List[UInt8]
    var buf: List[UInt8]
    var pos: Int  # archive bytes so far (CPython start_dir)
    var path: String
    var to_file: Bool
    var closed: Bool

    def __init__(out self, compression: Int = ZIP_STORED, compresslevel: Int = -1, allow_zip64: Bool = True):
        self.compression = compression
        self.compresslevel = compresslevel
        self.allow_zip64 = allow_zip64
        self.zip64_limit = ZIP64_LIMIT
        self.filecount_limit = ZIP_FILECOUNT_LIMIT
        self.infos = List[ZipInfo]()
        self.comment = List[UInt8]()
        self.buf = List[UInt8]()
        self.pos = 0
        self.path = String()
        self.to_file = False
        self.closed = False

    @staticmethod
    def create(path: String, compression: Int = ZIP_STORED, compresslevel: Int = -1, allow_zip64: Bool = True) raises -> ZipWriter:
        var w = ZipWriter(compression, compresslevel, allow_zip64)
        w.path = path.copy()
        w.to_file = True
        with open(path, "w"):
            pass  # create or truncate; the archive is appended at close
        return w^

    def set_comment(mut self, comment: Span[UInt8, _]):
        self.comment = List[UInt8](comment[: min(len(comment), ZIP_MAX_COMMENT)])

    def _flush(mut self) raises:
        if self.to_file and len(self.buf) > 0:
            with open(self.path, "a") as f:
                f.write_bytes(Span(self.buf))
            self.buf.clear()

    def to_bytes(self) raises -> List[UInt8]:
        if self.to_file:
            raise Error("ValueError: to_bytes needs an in-memory writer")
        return self.buf.copy()

    def _write_member(mut self, var zinfo: ZipInfo, data: Span[UInt8, _]) raises:
        if self.closed:
            raise Error("ValueError: Attempt to write to ZIP archive that was already closed")
        zinfo.file_size = len(data)
        zinfo.compress_size = 0
        zinfo.CRC = 0
        zinfo.flag_bits = MASK_UTF_FILENAME
        if zinfo.external_attr == 0:
            zinfo.external_attr = 0o600 << 16
        var zip64 = Float64(zinfo.file_size) * 1.05 > Float64(self.zip64_limit)
        if not self.allow_zip64 and zip64:
            raise _large("Filesize")
        zinfo.header_offset = self.pos
        self._write_check(zinfo)
        var comp = List[UInt8]()
        if zinfo.compress_type == ZIP_DEFLATED:
            comp = deflate_raw(data, zinfo.compress_level, True)
        else:
            comp = List[UInt8](data)
        zinfo.CRC = crc32(data)
        zinfo.compress_size = len(comp)
        if not zip64:
            if zinfo.file_size > self.zip64_limit:
                raise Error("RuntimeError: File size too large, try using force_zip64")
            if zinfo.compress_size > self.zip64_limit:
                raise Error("RuntimeError: Compressed size too large, try using force_zip64")
        var header = zinfo.file_header(zip64)
        self.buf.extend(Span(header))
        self.buf.extend(Span(comp))
        self.pos += len(header) + len(comp)
        self.infos.append(zinfo^)
        self._flush()

    def _write_check(self, zinfo: ZipInfo) raises:
        var ct = zinfo.compress_type
        if ct != ZIP_STORED and ct != ZIP_DEFLATED:
            if ct == 12:
                raise not_implemented("compression type 12 (bzip2)")
            if ct == 14:
                raise not_implemented("compression type 14 (lzma)")
            if ct == 93:
                raise not_implemented("compression type 93 (zstd)")
            raise not_implemented("That compression method is not supported")
        if not self.allow_zip64:
            if len(self.infos) >= self.filecount_limit:
                raise _large("Files count")
            elif zinfo.file_size > self.zip64_limit:
                raise _large("Filesize")
            elif zinfo.header_offset > self.zip64_limit:
                raise _large("Zipfile size")

    def writestr(mut self, name: String, data: Span[UInt8, _], compress_type: Int = -1, compresslevel: Int = -2, date_time: Array[Int, 6] = make_dt(0, 0, 0, 0, 0, 0)) raises:
        """ZipFile.writestr(name, data) with CPython's ZipInfo._for_archive defaults. date_time year 0 (the default)
        means SOURCE_DATE_EPOCH when set, else 1980-01-01 (CPython would read the clock)."""
        var dt = date_time.copy()
        if dt[0] == 0:
            var sde = getenv("SOURCE_DATE_EPOCH")
            dt = _gmtime(Int(sde)) if sde.byte_length() > 0 else make_dt()
        var zi = ZipInfo(name, dt)
        zi.compress_type = self.compression
        zi.compress_level = self.compresslevel
        zi.external_attr = (0o40775 << 16) | 0x10 if name.endswith("/") else 0o600 << 16
        if compress_type != -1:
            zi.compress_type = compress_type
        if compresslevel != -2:
            zi.compress_level = compresslevel
        self._write_member(zi^, data)

    def writestr(mut self, var info: ZipInfo, data: Span[UInt8, _]) raises:
        """ZipFile.writestr(ZipInfo, data): the info's own type, level and attributes are used."""
        self._write_member(info^, data)

    def mkdir(mut self, name: String, mode: Int = 511) raises:
        var dn = name.copy()
        if not dn.endswith("/"):
            dn += "/"
        var zi = ZipInfo(dn)
        zi.external_attr = (((0o40000 | mode) & 0xFFFF) << 16) | 0x10
        zi.header_offset = self.pos
        self._write_check(zi)
        var header = zi.file_header(False)
        self.buf.extend(Span(header))
        self.pos += len(header)
        self.infos.append(zi^)
        self._flush()

    def close(mut self) raises:
        """Writes the central directory and the end records."""
        if self.closed:
            return
        var tail = List[UInt8]()
        var start_dir = self.pos
        for i in range(len(self.infos)):
            ref zi = self.infos[i]
            var dosdate = ((zi.date_time[0] - 1980) << 9 | zi.date_time[1] << 5 | zi.date_time[2]) & 0xFFFF
            var dostime = (zi.date_time[3] << 11 | zi.date_time[4] << 5 | (zi.date_time[5] // 2)) & 0xFFFF
            var vals = List[Int]()
            var file_size = zi.file_size
            var compress_size = zi.compress_size
            if zi.file_size > self.zip64_limit or zi.compress_size > self.zip64_limit:
                vals.append(zi.file_size)
                vals.append(zi.compress_size)
                file_size = 0xFFFFFFFF
                compress_size = 0xFFFFFFFF
            var header_offset = zi.header_offset
            if zi.header_offset > self.zip64_limit:
                vals.append(zi.header_offset)
                header_offset = 0xFFFFFFFF
            var extra_data = zi.extra.copy()
            var min_version = 0
            if len(vals) > 0:
                var stripped = extra_strip_zip64(Span(zi.extra))
                extra_data = List[UInt8]()
                put16(extra_data, 1)
                put16(extra_data, 8 * len(vals))
                for v in vals:
                    put64(extra_data, v)
                extra_data.extend(Span(stripped))
                min_version = ZIP64_VERSION
            var extract_version = max(min_version, zi.extract_version)
            var create_version = max(min_version, zi.create_version)
            var name = List[UInt8]()
            var flags = zi.encode_name_flags(name)
            tail.append(0x50)
            tail.append(0x4B)
            tail.append(1)
            tail.append(2)
            tail.append(UInt8(create_version & 0xFF))
            tail.append(UInt8(zi.create_system & 0xFF))
            tail.append(UInt8(extract_version & 0xFF))
            tail.append(UInt8(zi.reserved & 0xFF))
            put16(tail, flags)
            put16(tail, zi.compress_type)
            put16(tail, dostime)
            put16(tail, dosdate)
            put32(tail, Int(zi.CRC))
            put32(tail, compress_size)
            put32(tail, file_size)
            put16(tail, len(name))
            put16(tail, len(extra_data))
            put16(tail, len(zi.comment))
            put16(tail, 0)
            put16(tail, zi.internal_attr)
            put32(tail, zi.external_attr)
            put32(tail, header_offset)
            tail.extend(Span(name))
            tail.extend(Span(extra_data))
            tail.extend(Span(zi.comment))
        var pos2 = start_dir + len(tail)
        var count = len(self.infos)
        var cd_size = pos2 - start_dir
        var cd_offset = start_dir
        var requires = String()
        if count > self.filecount_limit:
            requires = "Files count"
        elif cd_offset > self.zip64_limit:
            requires = "Central directory offset"
        elif cd_size > self.zip64_limit:
            requires = "Central directory size"
        if requires.byte_length() > 0:
            if not self.allow_zip64:
                raise _large(requires)
            tail.append(0x50)
            tail.append(0x4B)
            tail.append(6)
            tail.append(6)
            put64(tail, 56 - 12)
            put16(tail, 45)
            put16(tail, 45)
            put32(tail, 0)
            put32(tail, 0)
            put64(tail, count)
            put64(tail, count)
            put64(tail, cd_size)
            put64(tail, cd_offset)
            tail.append(0x50)
            tail.append(0x4B)
            tail.append(6)
            tail.append(7)
            put32(tail, 0)
            put64(tail, pos2)
            put32(tail, 1)
            count = min(count, 0xFFFF)
            cd_size = min(cd_size, 0xFFFFFFFF)
            cd_offset = min(cd_offset, 0xFFFFFFFF)
        tail.append(0x50)
        tail.append(0x4B)
        tail.append(5)
        tail.append(6)
        put16(tail, 0)
        put16(tail, 0)
        put16(tail, count)
        put16(tail, count)
        put32(tail, cd_size)
        put32(tail, cd_offset)
        put16(tail, len(self.comment))
        tail.extend(Span(self.comment))
        self.buf.extend(Span(tail))
        self.pos += len(tail)
        self._flush()
        self.closed = True
