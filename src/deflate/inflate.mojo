"""Raw DEFLATE decoder (RFC 1951), pure Mojo. Errors carry zlib's own texts. A 64-bit bit buffer and
10-bit first-level tables make the hot loop one lookup per symbol; longer codes take a canonical walk."""
from std.memory import unsafe_memcpy

comptime INF_END = 0  # final block finished
comptime INF_LIMIT = 1  # max_out bytes produced, stream not finished
comptime INF_INPUT = 2  # input ended inside the stream
comptime INF_BAD = 3  # corrupt stream, msg says why

comptime _PB = 10  # first-level table bits
comptime _LBASE = SIMD[DType.uint16, 32](3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0, 0)
comptime _LEXT = SIMD[DType.uint8, 32](0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0, 0)
comptime _DBASE = SIMD[DType.uint16, 32](1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 0, 0)
comptime _DEXT = SIMD[DType.uint8, 32](0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0)
comptime _CLORDER = SIMD[DType.uint8, 32](16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)


def _up(mut l: List[UInt8]) -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(l.unsafe_ptr()))


struct InflateResult(Movable):
    var out: List[UInt8]
    var status: Int
    var consumed: Int  # input bytes used (whole bytes; an unfinished final byte counts as used)
    var msg: String

    def __init__(out self, var out_: List[UInt8], status: Int, consumed: Int, var msg: String):
        self.out = out_^
        self.status = status
        self.consumed = consumed
        self.msg = msg^


struct _Huff(Movable):
    """Canonical Huffman decoder: tab[bits] = symbol | len << 9 for codes up to _PB bits (0 = longer or none),
    count/sym for the canonical walk of the rest."""
    var tab: List[UInt16]
    var count: List[UInt16]
    var sym: List[UInt16]

    def __init__(out self):
        self.tab = List[UInt16](length=1 << _PB, fill=0)
        self.count = List[UInt16](length=16, fill=0)
        self.sym = List[UInt16](length=320, fill=0)

    def build(mut self, lens: Span[UInt8, _], n: Int, is_codes: Bool) -> Int:
        """0 ok, 1 over-subscribed, 2 incomplete (zlib's rules: only a lone 1-bit code may be incomplete)."""
        for i in range(16):
            self.count[i] = 0
        for i in range(n):
            self.count[Int(lens[i])] += 1
        var maxlen = 15
        while maxlen >= 1 and self.count[maxlen] == 0:
            maxlen -= 1
        if maxlen == 0:
            for i in range(1 << _PB):
                self.tab[i] = 0
            return 0
        var left = 1
        for l in range(1, 16):
            left <<= 1
            left -= Int(self.count[l])
            if left < 0:
                return 1
        if left > 0 and (is_codes or maxlen != 1):
            return 2
        var offs = Array[Int, 17](fill=0)
        for l in range(1, 16):
            offs[l + 1] = offs[l] + Int(self.count[l])
        for i in range(n):
            var l = Int(lens[i])
            if l != 0:
                self.sym[offs[l]] = UInt16(i)
                offs[l] += 1
        for i in range(1 << _PB):
            self.tab[i] = 0
        var code = 0
        var idx = 0
        for l in range(1, _PB + 1):
            for _ in range(Int(self.count[l])):
                var rev = 0
                for b in range(l):
                    rev |= ((code >> b) & 1) << (l - 1 - b)
                var e = UInt16(Int(self.sym[idx]) | (l << 9))
                var step = 1 << l
                var j = rev
                while j < (1 << _PB):
                    self.tab[j] = e
                    j += step
                code += 1
                idx += 1
            code <<= 1
        return 0


struct _Bits:
    var p: Int  # address of the input
    var n: Int
    var pos: Int
    var hold: UInt64
    var nbits: Int

    def __init__(out self, p: Int, n: Int):
        self.p = p
        self.n = n
        self.pos = 0
        self.hold = 0
        self.nbits = 0

    @always_inline
    def refill(mut self):
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.p)
        if self.pos + 8 <= self.n:
            self.hold |= src.unsafe_offset(self.pos).unsafe_bitcast[UInt64]()[] << UInt64(self.nbits)
            self.pos += (63 - self.nbits) >> 3
            self.nbits |= 56
        else:
            while self.nbits <= 56 and self.pos < self.n:
                self.hold |= UInt64(src.unsafe_offset(self.pos)[]) << UInt64(self.nbits)
                self.pos += 1
                self.nbits += 8

    @always_inline
    def take(mut self, k: Int) -> Int:
        var v = Int(self.hold & ((UInt64(1) << UInt64(k)) - 1))
        self.hold >>= UInt64(k)
        self.nbits -= k
        return v


def _decode(mut b: _Bits, h: _Huff) -> Int:
    """Next symbol, -1 when the input ends first, -2 for an invalid code."""
    if b.nbits < 15:
        b.refill()
    var e = Int(h.tab[Int(b.hold & ((UInt64(1) << UInt64(_PB)) - 1))])
    if e != 0:
        var l = e >> 9
        if l > b.nbits:
            return -1
        b.hold >>= UInt64(l)
        b.nbits -= l
        return e & 511
    var code = 0
    var first = 0
    var index = 0
    var hold = b.hold
    for l in range(1, 16):
        if l > b.nbits:
            return -1
        code |= Int(hold & 1)
        hold >>= 1
        var cnt = Int(h.count[l])
        if code - cnt < first:
            b.hold >>= UInt64(l)
            b.nbits -= l
            return Int(h.sym[index + (code - first)])
        index += cnt
        first += cnt
        first <<= 1
        code <<= 1
    return -2


def inflate_raw(src: Span[UInt8, _], max_out: Int = -1, size_hint: Int = 0) -> InflateResult:
    """Inflates a raw deflate stream. max_out >= 0 stops after that many bytes (status INF_LIMIT unless the
    stream ends exactly there); size_hint pre-sizes the output."""
    var cap = max(size_hint, 4096)
    if max_out >= 0 and max_out < cap:
        cap = max(max_out, 1)
    var out = List[UInt8](unsafe_uninit_length=cap)
    var olen = 0
    var b = _Bits(Int(src.unsafe_ptr()), len(src))
    var lit = _Huff()
    var dist = _Huff()
    var lens = Array[UInt8, 320](fill=0)
    var status = INF_END
    var msg = String()
    var last = False
    var limit = max_out if max_out >= 0 else (1 << 62)
    while not last:
        b.refill()
        if b.nbits < 3:
            status = INF_INPUT
            break
        last = b.take(1) == 1
        var typ = b.take(2)
        if typ == 0:
            var drop = b.nbits & 7
            _ = b.take(drop)
            b.refill()
            if b.nbits < 32:
                status = INF_INPUT
                break
            var ln = b.take(16)
            var nln = b.take(16)
            if ln != (nln ^ 0xFFFF):
                status = INF_BAD
                msg = "invalid stored block lengths"
                break
            # whole bytes still in the bit buffer first, then straight from the input (stray look-ahead bits dropped)
            while ln > 0:
                if olen >= limit:
                    status = INF_LIMIT
                    break
                if olen == len(out):
                    out.resize(unsafe_uninit_length=len(out) * 2)
                if b.nbits >= 8:
                    _up(out).unsafe_offset(olen)[] = UInt8(b.take(8))
                    olen += 1
                    ln -= 1
                    continue
                b.hold = 0
                var c = min(ln, b.n - b.pos, limit - olen, len(out) - olen)
                if c <= 0:
                    status = INF_INPUT
                    break
                unsafe_memcpy(dest=_up(out).unsafe_offset(olen), src=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=b.p).unsafe_offset(b.pos), count=c)
                b.pos += c
                olen += c
                ln -= c
            if status != INF_END:
                break
            continue
        elif typ == 3:
            status = INF_BAD
            msg = "invalid block type"
            break
        elif typ == 1:
            for i in range(144):
                lens[i] = 8
            for i in range(144, 256):
                lens[i] = 9
            for i in range(256, 280):
                lens[i] = 7
            for i in range(280, 288):
                lens[i] = 8
            _ = lit.build(Span(lens), 288, False)
            for i in range(32):
                lens[i] = 5
            _ = dist.build(Span(lens), 32, False)
        else:
            b.refill()
            if b.nbits < 14:
                status = INF_INPUT
                break
            var nlen = b.take(5) + 257
            var ndist = b.take(5) + 1
            var ncode = b.take(4) + 4
            if nlen > 286 or ndist > 30:
                status = INF_BAD
                msg = "too many length or distance symbols"
                break
            for i in range(19):
                lens[i] = 0
            for i in range(ncode):
                b.refill()
                if b.nbits < 3:
                    status = INF_INPUT
                    break
                lens[Int(_CLORDER[i])] = UInt8(b.take(3))
            if status != INF_END:
                break
            if lit.build(Span(lens), 19, True) != 0:
                status = INF_BAD
                msg = "invalid code lengths set"
                break
            var have = 0
            var cl = Array[UInt8, 320](fill=0)
            while have < nlen + ndist:
                var s = _decode(b, lit)
                if s == -1:
                    status = INF_INPUT
                    break
                if s < 0:
                    status = INF_BAD
                    msg = "invalid code lengths set"
                    break
                if s < 16:
                    cl[have] = UInt8(s)
                    have += 1
                    continue
                var rep: Int
                var val = 0
                var need = 2 if s == 16 else (3 if s == 17 else 7)
                if b.nbits < need:
                    b.refill()
                    if b.nbits < need:
                        status = INF_INPUT
                        break
                if s == 16:
                    if have == 0:
                        status = INF_BAD
                        msg = "invalid bit length repeat"
                        break
                    val = Int(cl[have - 1])
                    rep = 3 + b.take(2)
                elif s == 17:
                    rep = 3 + b.take(3)
                else:
                    rep = 11 + b.take(7)
                if have + rep > nlen + ndist:
                    status = INF_BAD
                    msg = "invalid bit length repeat"
                    break
                for _ in range(rep):
                    cl[have] = UInt8(val)
                    have += 1
            if status != INF_END:
                break
            if cl[256] == 0:
                status = INF_BAD
                msg = "invalid code -- missing end-of-block"
                break
            if lit.build(Span(cl), nlen, False) != 0:
                status = INF_BAD
                msg = "invalid literal/lengths set"
                break
            var dl = Array[UInt8, 320](fill=0)
            for i in range(ndist):
                dl[i] = cl[nlen + i]
            if dist.build(Span(dl), ndist, False) != 0:
                status = INF_BAD
                msg = "invalid distances set"
                break
        # compressed block body
        var op = _up(out)
        while True:
            var s = _decode(b, lit)
            if s == -1:
                status = INF_INPUT
                break
            if s < 0 or s > 285:
                status = INF_BAD
                msg = "invalid literal/length code"
                break
            if s == 256:
                break
            if s < 256:
                if olen >= limit:
                    status = INF_LIMIT
                    break
                if olen == len(out):
                    out.resize(unsafe_uninit_length=len(out) * 2)
                    op = _up(out)
                op.unsafe_offset(olen)[] = UInt8(s)
                olen += 1
                continue
            var li = s - 257
            var le = Int(_LEXT[li])
            if b.nbits < le:
                b.refill()
                if b.nbits < le:
                    status = INF_INPUT
                    break
            var length = Int(_LBASE[li]) + b.take(le)
            var ds = _decode(b, dist)
            if ds == -1:
                status = INF_INPUT
                break
            if ds < 0 or ds > 29:
                status = INF_BAD
                msg = "invalid distance code"
                break
            var de = Int(_DEXT[ds])
            if b.nbits < de:
                b.refill()
                if b.nbits < de:
                    status = INF_INPUT
                    break
            var d = Int(_DBASE[ds]) + b.take(de)
            if d > olen:
                status = INF_BAD
                msg = "invalid distance too far back"
                break
            if olen >= limit:
                status = INF_LIMIT
                break
            var n = min(length, limit - olen)
            while olen + n > len(out):
                out.resize(unsafe_uninit_length=len(out) * 2)
                op = _up(out)
            var dst = op.unsafe_offset(olen)
            var srcp = op.unsafe_offset(olen - d)
            if d >= n:
                unsafe_memcpy(dest=dst, src=srcp, count=n)
            elif d == 1:
                var v = srcp[]
                for i in range(n):
                    dst.unsafe_offset(i)[] = v
            else:
                for i in range(n):
                    dst.unsafe_offset(i)[] = srcp.unsafe_offset(i)[]
            olen += n
            if n < length:
                status = INF_LIMIT
                break
        if status != INF_END:
            break
    var used = b.pos - (b.nbits >> 3)
    out.shrink(olen)
    return InflateResult(out^, status, used, msg^)


def inflate(src: Span[UInt8, _], size_hint: Int = 0) raises -> List[UInt8]:
    """The whole inflated stream; raises zlib's texts on corrupt or truncated input. Data after the end is ignored."""
    var r = inflate_raw(src, -1, size_hint)
    if r.status == INF_BAD:
        raise Error("Error -3 while decompressing data: ", r.msg)
    if r.status != INF_END:
        raise Error("Error -5 while decompressing data: incomplete or truncated stream")
    var o = List[UInt8]()
    swap(o, r.out)
    return o^
