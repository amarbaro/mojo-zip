"""CRC-32 (IEEE, reflected, the zip/gzip/PNG one), pure Mojo: slicing-by-8 over one comptime table."""
from std.builtin.globals import global_constant


def _make_table() -> Array[UInt32, 2048]:
    var t = Array[UInt32, 2048](fill=0)
    for i in range(256):
        var c = UInt32(i)
        for _ in range(8):
            c = (c >> 1) ^ (UInt32(0xEDB88320) if (c & 1) != 0 else UInt32(0))
        t[i] = c
    for i in range(256):
        var c = t[i]
        for k in range(1, 8):
            c = t[Int(c & 0xFF)] ^ (c >> 8)
            t[k * 256 + i] = c
    return t^


comptime _TABLE = _make_table()


def crc32(data: Span[UInt8, _], start: UInt32 = 0) -> UInt32:
    """Equals Python zlib.crc32(data, start). Chain a running value with start."""
    var t = Pointer(to=global_constant[_TABLE]()).unsafe_bitcast[UInt32]()
    var p = data.unsafe_ptr()
    var n = len(data)
    var c = ~start
    var i = 0
    while n - i >= 8:
        var a = p.unsafe_offset(i).unsafe_bitcast[UInt32]()[] ^ c
        var b = p.unsafe_offset(i + 4).unsafe_bitcast[UInt32]()[]
        c = (t.unsafe_offset(1792 + Int(a & 0xFF))[] ^ t.unsafe_offset(1536 + Int((a >> 8) & 0xFF))[]
            ^ t.unsafe_offset(1280 + Int((a >> 16) & 0xFF))[] ^ t.unsafe_offset(1024 + Int(a >> 24))[]
            ^ t.unsafe_offset(768 + Int(b & 0xFF))[] ^ t.unsafe_offset(512 + Int((b >> 8) & 0xFF))[]
            ^ t.unsafe_offset(256 + Int((b >> 16) & 0xFF))[] ^ t.unsafe_offset(Int(b >> 24))[])
        i += 8
    while i < n:
        c = t.unsafe_offset(Int((c ^ UInt32(p.unsafe_offset(i)[])) & 0xFF))[] ^ (c >> 8)
        i += 1
    return ~c
