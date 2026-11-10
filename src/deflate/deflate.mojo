"""Raw DEFLATE encoder: a line-by-line port of zlib 1.3.2 deflate.c and trees.c (hash chains, lazy matching,
the per-level configuration table, block splitting, Huffman tree construction), so the output bytes equal
zlib's for every level. zlib is Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler (zlib licence, see NOTICE).
The state keeps zlib's names; avail_in/avail_out/next_out are modelled because level 0 (stored) block sizes
depend on how much output room the caller offers."""
from std.memory import unsafe_memcpy
from std.builtin.globals import global_constant

comptime MIN_MATCH = 3
comptime MAX_MATCH = 258
comptime MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1
comptime LITERALS = 256
comptime L_CODES = 286
comptime D_CODES = 30
comptime BL_CODES = 19
comptime HEAP_SIZE = 2 * L_CODES + 1
comptime MAX_BITS = 15
comptime END_BLOCK = 256
comptime TOO_FAR = 4096
comptime MAX_STORED = 65535
comptime WIN_INIT = MAX_MATCH
comptime Z_NO_FLUSH = 0
comptime Z_FINISH = 4
comptime Z_OK = 0
comptime Z_STREAM_END = 1
comptime Z_BUF_ERROR = -5
comptime _NEED_MORE = 0
comptime _BLOCK_DONE = 1
comptime _FINISH_STARTED = 2
comptime _FINISH_DONE = 3

# node n of a tree is the pair ct[base + 2n] = Freq/Code, ct[base + 2n + 1] = Dad/Len (zlib's ct_data unions)
comptime _LT = 0
comptime _DT = 2 * HEAP_SIZE
comptime _BT = _DT + 2 * (2 * D_CODES + 1)
comptime _SLT = _BT + 2 * (2 * BL_CODES + 1)
comptime _SDT = _SLT + 2 * (L_CODES + 2)
comptime _CT_WORDS = _SDT + 2 * D_CODES

comptime _BL_ORDER = SIMD[DType.uint8, 32](16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
# config table: good_length, max_lazy, nice_length, max_chain, func (0 stored, 1 fast, 2 slow)
comptime _CFG = SIMD[DType.uint16, 64](
    0, 0, 0, 0, 0, 4, 4, 8, 4, 1, 4, 5, 16, 8, 1, 4, 6, 32, 32, 1, 4, 4, 16, 16, 2, 8, 16, 32, 32, 2,
    8, 16, 128, 128, 2, 8, 32, 128, 256, 2, 32, 128, 258, 1024, 2, 32, 258, 258, 4096, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)


def _length_code_table() -> Array[UInt8, 256]:
    var t = Array[UInt8, 256](fill=0)
    var length = 0
    var code = 0
    while code < 28:
        var ext = 0 if code < 8 else (code >> 2) - 1
        for _ in range(1 << ext):
            t[length] = UInt8(code)
            length += 1
        code += 1
    t[length - 1] = UInt8(code)
    return t^


def _dist_code_table() -> Array[UInt8, 512]:
    var t = Array[UInt8, 512](fill=0)
    var dist = 0
    var code = 0
    while code < 16:
        var ext = 0 if code < 4 else (code >> 1) - 1
        for _ in range(1 << ext):
            t[dist] = UInt8(code)
            dist += 1
        code += 1
    dist >>= 7
    while code < D_CODES:
        var ext = (code >> 1) - 1
        for _ in range(1 << (ext - 7)):
            t[256 + dist] = UInt8(code)
            dist += 1
        code += 1
    return t^


def _base_length_table() -> Array[UInt16, 32]:
    var t = Array[UInt16, 32](fill=0)
    var length = 0
    for code in range(28):
        t[code] = UInt16(length)
        var ext = 0 if code < 8 else (code >> 2) - 1
        length += 1 << ext
    return t^


def _base_dist_table() -> Array[UInt16, 32]:
    var t = Array[UInt16, 32](fill=0)
    var dist = 0
    for code in range(D_CODES):
        t[code] = UInt16(dist)
        var ext = 0 if code < 4 else (code >> 1) - 1
        dist += 1 << ext
    return t^


comptime _LENCODE = _length_code_table()
comptime _DISTCODE = _dist_code_table()
comptime _BASELEN = _base_length_table()
comptime _BASEDIST = _base_dist_table()


@always_inline
def _pu8(mut l: List[UInt8]) -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(l.unsafe_ptr()))


@always_inline
def _pu16(mut l: List[UInt16]) -> Pointer[UInt16, MutUntrackedOrigin]:
    return Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=Int(l.unsafe_ptr()))


@always_inline
def _lencode(i: Int) -> Int:
    return Int(Pointer(to=global_constant[_LENCODE]()).unsafe_bitcast[UInt8]().unsafe_offset(i)[])


@always_inline
def _d_code(dist: Int) -> Int:
    var t = Pointer(to=global_constant[_DISTCODE]()).unsafe_bitcast[UInt8]()
    return Int(t.unsafe_offset(dist if dist < 256 else 256 + (dist >> 7))[])


def _extra_bits(kind: Int, i: Int) -> Int:
    if kind == 0:  # length codes
        return 0 if (i < 8 or i == 28) else (i >> 2) - 1
    if kind == 1:  # distance codes
        return 0 if i < 4 else (i >> 1) - 1
    return 2 if i == 16 else (3 if i == 17 else (7 if i == 18 else 0))


def _bi_reverse(code: Int, length: Int) -> Int:
    var res = 0
    var c = code
    var n = length
    while True:
        res |= c & 1
        c >>= 1
        res <<= 1
        n -= 1
        if n <= 0:
            break
    return res >> 1


struct Deflater(Movable):
    var level: Int
    var w_size: Int
    var w_mask: Int
    var hash_size: Int
    var hash_mask: Int
    var hash_shift: Int
    var lit_bufsize: Int
    var pending_buf_size: Int
    var window: List[UInt8]
    var prev: List[UInt16]
    var head: List[UInt16]
    var pending_buf: List[UInt8]
    var sym_d: List[UInt16]
    var sym_l: List[UInt8]
    var ct: List[UInt16]
    var heap: List[Int32]
    var depth: List[UInt8]
    var bl_count: List[UInt16]
    var heap_len: Int
    var heap_max: Int
    var l_max: Int
    var d_max: Int
    var bl_max: Int
    var opt_len: Int
    var static_len: Int
    var sym_next: Int
    var sym_end: Int
    var matches: Int
    var bi_buf: Int
    var bi_valid: Int
    var pending: Int
    var pending_out: Int
    var window_size: Int
    var ins_h: Int
    var block_start: Int
    var match_length: Int
    var prev_match: Int
    var match_available: Int
    var strstart: Int
    var match_start: Int
    var lookahead: Int
    var prev_length: Int
    var max_chain_length: Int
    var max_lazy_match: Int
    var good_match: Int
    var nice_match: Int
    var insert: Int
    var high_water: Int
    var last_flush: Int
    var status: Int  # 0 busy, 1 finished
    var in_addr: Int
    var in_len: Int
    var in_pos: Int
    var out: List[UInt8]
    var out_pos: Int
    var avail_out: Int

    def __init__(out self, level: Int):
        self.level = 6 if level == -1 else level
        self.w_size = 1 << 15
        self.w_mask = self.w_size - 1
        self.hash_size = 1 << 15
        self.hash_mask = self.hash_size - 1
        self.hash_shift = (15 + MIN_MATCH - 1) // MIN_MATCH
        self.lit_bufsize = 1 << 14
        self.pending_buf_size = self.lit_bufsize * 4
        self.window = List[UInt8](length=2 * self.w_size, fill=0)
        self.prev = List[UInt16](length=self.w_size, fill=0)
        self.head = List[UInt16](length=self.hash_size, fill=0)
        self.pending_buf = List[UInt8](length=self.pending_buf_size, fill=0)
        self.sym_d = List[UInt16](length=self.lit_bufsize, fill=0)
        self.sym_l = List[UInt8](length=self.lit_bufsize, fill=0)
        self.ct = List[UInt16](length=_CT_WORDS, fill=0)
        self.heap = List[Int32](length=HEAP_SIZE + 1, fill=0)
        self.depth = List[UInt8](length=HEAP_SIZE + 1, fill=0)
        self.bl_count = List[UInt16](length=MAX_BITS + 1, fill=0)
        self.heap_len = 0
        self.heap_max = 0
        self.l_max = 0
        self.d_max = 0
        self.bl_max = 0
        self.opt_len = 0
        self.static_len = 0
        self.sym_next = 0
        self.sym_end = self.lit_bufsize - 1
        self.matches = 0
        self.bi_buf = 0
        self.bi_valid = 0
        self.pending = 0
        self.pending_out = 0
        self.window_size = 2 * self.w_size
        self.ins_h = 0
        self.block_start = 0
        self.match_length = MIN_MATCH - 1
        self.prev_match = 0
        self.match_available = 0
        self.strstart = 0
        self.match_start = 0
        self.lookahead = 0
        self.prev_length = MIN_MATCH - 1
        self.max_chain_length = Int(_CFG[self.level * 5 + 3])
        self.max_lazy_match = Int(_CFG[self.level * 5 + 1])
        self.good_match = Int(_CFG[self.level * 5])
        self.nice_match = Int(_CFG[self.level * 5 + 2])
        self.insert = 0
        self.high_water = 0
        self.last_flush = -2
        self.status = 0
        self.in_addr = 0
        self.in_len = 0
        self.in_pos = 0
        self.out = List[UInt8]()
        self.out_pos = 0
        self.avail_out = 0
        self._static_init()
        self._init_block()

    # ---- trees.c -------------------------------------------------------------------------------------------

    def _static_init(mut self):
        var t = _pu16(self.ct)
        var cnt = _pu16(self.bl_count)
        for i in range(MAX_BITS + 1):
            cnt.unsafe_offset(i)[] = 0
        var n = 0
        while n <= 143:
            t.unsafe_offset(_SLT + 2 * n + 1)[] = 8
            cnt.unsafe_offset(8)[] += 1
            n += 1
        while n <= 255:
            t.unsafe_offset(_SLT + 2 * n + 1)[] = 9
            cnt.unsafe_offset(9)[] += 1
            n += 1
        while n <= 279:
            t.unsafe_offset(_SLT + 2 * n + 1)[] = 7
            cnt.unsafe_offset(7)[] += 1
            n += 1
        while n <= 287:
            t.unsafe_offset(_SLT + 2 * n + 1)[] = 8
            cnt.unsafe_offset(8)[] += 1
            n += 1
        self._gen_codes(_SLT, L_CODES + 1, cnt)
        for i in range(D_CODES):
            t.unsafe_offset(_SDT + 2 * i + 1)[] = 5
            t.unsafe_offset(_SDT + 2 * i)[] = UInt16(_bi_reverse(i, 5))

    def _gen_codes(mut self, tb: Int, max_code: Int, bl_count: Pointer[UInt16, MutUntrackedOrigin]):
        var t = _pu16(self.ct)
        var next_code = List[Int](length=MAX_BITS + 2, fill=0)
        var code = 0
        for bits in range(1, MAX_BITS + 1):
            code = (code + Int(bl_count.unsafe_offset(bits - 1)[])) << 1
            next_code[bits] = code & 0xFFFF
        for n in range(max_code + 1):
            var ln = Int(t.unsafe_offset(tb + 2 * n + 1)[])
            if ln == 0:
                continue
            t.unsafe_offset(tb + 2 * n)[] = UInt16(_bi_reverse(next_code[ln], ln))
            next_code[ln] = (next_code[ln] + 1) & 0xFFFF

    def _init_block(mut self):
        var t = _pu16(self.ct)
        for n in range(L_CODES):
            t.unsafe_offset(_LT + 2 * n)[] = 0
        for n in range(D_CODES):
            t.unsafe_offset(_DT + 2 * n)[] = 0
        for n in range(BL_CODES):
            t.unsafe_offset(_BT + 2 * n)[] = 0
        t.unsafe_offset(_LT + 2 * END_BLOCK)[] = 1
        self.opt_len = 0
        self.static_len = 0
        self.sym_next = 0
        self.matches = 0

    @always_inline
    def _put_byte(mut self, c: Int):
        _pu8(self.pending_buf).unsafe_offset(self.pending)[] = UInt8(c & 0xFF)
        self.pending += 1

    @always_inline
    def _put_short(mut self, w: Int):
        self._put_byte(w & 0xFF)
        self._put_byte((w & 0xFFFF) >> 8)

    @always_inline
    def _send_bits(mut self, value: Int, length: Int):
        if self.bi_valid > 16 - length:
            self.bi_buf |= (value << self.bi_valid) & 0xFFFF
            self._put_short(self.bi_buf)
            self.bi_buf = (value & 0xFFFF) >> (16 - self.bi_valid)
            self.bi_valid += length - 16
        else:
            self.bi_buf |= ((value & 0xFFFF) << self.bi_valid) & 0xFFFF
            self.bi_valid += length

    @always_inline
    def _send_code(mut self, c: Int, tb: Int):
        var t = _pu16(self.ct)
        self._send_bits(Int(t.unsafe_offset(tb + 2 * c)[]), Int(t.unsafe_offset(tb + 2 * c + 1)[]))

    def _bi_flush(mut self):
        if self.bi_valid == 16:
            self._put_short(self.bi_buf)
            self.bi_buf = 0
            self.bi_valid = 0
        elif self.bi_valid >= 8:
            self._put_byte(self.bi_buf)
            self.bi_buf >>= 8
            self.bi_valid -= 8

    def _bi_windup(mut self):
        if self.bi_valid > 8:
            self._put_short(self.bi_buf)
        elif self.bi_valid > 0:
            self._put_byte(self.bi_buf)
        self.bi_buf = 0
        self.bi_valid = 0

    def _smaller(mut self, tb: Int, n: Int, m: Int) -> Bool:
        var t = _pu16(self.ct)
        var fn_ = t.unsafe_offset(tb + 2 * n)[]
        var fm = t.unsafe_offset(tb + 2 * m)[]
        return fn_ < fm or (fn_ == fm and self.depth[n] <= self.depth[m])

    def _pqdownheap(mut self, tb: Int, k_in: Int):
        var k = k_in
        var v = Int(self.heap[k])
        var j = k << 1
        while j <= self.heap_len:
            if j < self.heap_len and self._smaller(tb, Int(self.heap[j + 1]), Int(self.heap[j])):
                j += 1
            if self._smaller(tb, v, Int(self.heap[j])):
                break
            self.heap[k] = self.heap[j]
            k = j
            j <<= 1
        self.heap[k] = Int32(v)

    def _gen_bitlen(mut self, tb: Int, stb: Int, ekind: Int, ebase: Int, max_length: Int, max_code: Int):
        var t = _pu16(self.ct)
        for bits in range(MAX_BITS + 1):
            self.bl_count[bits] = 0
        t.unsafe_offset(tb + 2 * Int(self.heap[self.heap_max]) + 1)[] = 0
        var overflow = 0
        var h = self.heap_max + 1
        while h < HEAP_SIZE:
            var n = Int(self.heap[h])
            var bits = Int(t.unsafe_offset(tb + 2 * Int(t.unsafe_offset(tb + 2 * n + 1)[]) + 1)[]) + 1
            if bits > max_length:
                bits = max_length
                overflow += 1
            t.unsafe_offset(tb + 2 * n + 1)[] = UInt16(bits)
            h += 1
            if n > max_code:
                continue
            self.bl_count[bits] += 1
            var xbits = 0
            if n >= ebase:
                xbits = _extra_bits(ekind, n - ebase)
            var f = Int(t.unsafe_offset(tb + 2 * n)[])
            self.opt_len += f * (bits + xbits)
            if stb >= 0:
                self.static_len += f * (Int(t.unsafe_offset(stb + 2 * n + 1)[]) + xbits)
        if overflow == 0:
            return
        while True:
            var bits = max_length - 1
            while self.bl_count[bits] == 0:
                bits -= 1
            self.bl_count[bits] -= 1
            self.bl_count[bits + 1] += 2
            self.bl_count[max_length] -= 1
            overflow -= 2
            if overflow <= 0:
                break
        h = HEAP_SIZE
        var bits = max_length
        while bits != 0:
            var n = Int(self.bl_count[bits])
            while n != 0:
                h -= 1
                var m = Int(self.heap[h])
                if m > max_code:
                    continue
                if Int(t.unsafe_offset(tb + 2 * m + 1)[]) != bits:
                    self.opt_len += (bits - Int(t.unsafe_offset(tb + 2 * m + 1)[])) * Int(t.unsafe_offset(tb + 2 * m)[])
                    t.unsafe_offset(tb + 2 * m + 1)[] = UInt16(bits)
                n -= 1
            bits -= 1

    def _build_tree(mut self, tb: Int, stb: Int, ekind: Int, ebase: Int, elems: Int, max_length: Int) -> Int:
        var t = _pu16(self.ct)
        var max_code = -1
        self.heap_len = 0
        self.heap_max = HEAP_SIZE
        for n in range(elems):
            if t.unsafe_offset(tb + 2 * n)[] != 0:
                self.heap_len += 1
                self.heap[self.heap_len] = Int32(n)
                max_code = n
                self.depth[n] = 0
            else:
                t.unsafe_offset(tb + 2 * n + 1)[] = 0
        while self.heap_len < 2:
            var node: Int
            if max_code < 2:
                max_code += 1
                node = max_code
            else:
                node = 0
            self.heap_len += 1
            self.heap[self.heap_len] = Int32(node)
            t.unsafe_offset(tb + 2 * node)[] = 1
            self.depth[node] = 0
            self.opt_len -= 1
            if stb >= 0:
                self.static_len -= Int(t.unsafe_offset(stb + 2 * node + 1)[])
        var n = self.heap_len // 2
        while n >= 1:
            self._pqdownheap(tb, n)
            n -= 1
        var node = elems
        while True:
            n = Int(self.heap[1])
            self.heap[1] = self.heap[self.heap_len]
            self.heap_len -= 1
            self._pqdownheap(tb, 1)
            var m = Int(self.heap[1])
            self.heap_max -= 1
            self.heap[self.heap_max] = Int32(n)
            self.heap_max -= 1
            self.heap[self.heap_max] = Int32(m)
            t.unsafe_offset(tb + 2 * node)[] = t.unsafe_offset(tb + 2 * n)[] + t.unsafe_offset(tb + 2 * m)[]
            self.depth[node] = UInt8((Int(self.depth[n]) if self.depth[n] >= self.depth[m] else Int(self.depth[m])) + 1)
            t.unsafe_offset(tb + 2 * n + 1)[] = UInt16(node)
            t.unsafe_offset(tb + 2 * m + 1)[] = UInt16(node)
            self.heap[1] = Int32(node)
            node += 1
            self._pqdownheap(tb, 1)
            if self.heap_len < 2:
                break
        self.heap_max -= 1
        self.heap[self.heap_max] = self.heap[1]
        self._gen_bitlen(tb, stb, ekind, ebase, max_length, max_code)
        self._gen_codes(tb, max_code, _pu16(self.bl_count))
        return max_code

    def _scan_tree(mut self, tb: Int, max_code: Int):
        var t = _pu16(self.ct)
        var prevlen = -1
        var nextlen = Int(t.unsafe_offset(tb + 1)[])
        var count = 0
        var max_count = 7
        var min_count = 4
        if nextlen == 0:
            max_count = 138
            min_count = 3
        t.unsafe_offset(tb + 2 * (max_code + 1) + 1)[] = 0xFFFF
        for n in range(max_code + 1):
            var curlen = nextlen
            nextlen = Int(t.unsafe_offset(tb + 2 * (n + 1) + 1)[])
            count += 1
            if count < max_count and curlen == nextlen:
                continue
            elif count < min_count:
                t.unsafe_offset(_BT + 2 * curlen)[] += UInt16(count)
            elif curlen != 0:
                if curlen != prevlen:
                    t.unsafe_offset(_BT + 2 * curlen)[] += 1
                t.unsafe_offset(_BT + 2 * 16)[] += 1
            elif count <= 10:
                t.unsafe_offset(_BT + 2 * 17)[] += 1
            else:
                t.unsafe_offset(_BT + 2 * 18)[] += 1
            count = 0
            prevlen = curlen
            if nextlen == 0:
                max_count = 138
                min_count = 3
            elif curlen == nextlen:
                max_count = 6
                min_count = 3
            else:
                max_count = 7
                min_count = 4

    def _send_tree(mut self, tb: Int, max_code: Int):
        var t = _pu16(self.ct)
        var prevlen = -1
        var nextlen = Int(t.unsafe_offset(tb + 1)[])
        var count = 0
        var max_count = 7
        var min_count = 4
        if nextlen == 0:
            max_count = 138
            min_count = 3
        for n in range(max_code + 1):
            var curlen = nextlen
            nextlen = Int(t.unsafe_offset(tb + 2 * (n + 1) + 1)[])
            count += 1
            if count < max_count and curlen == nextlen:
                continue
            elif count < min_count:
                while True:
                    self._send_code(curlen, _BT)
                    count -= 1
                    if count == 0:
                        break
            elif curlen != 0:
                if curlen != prevlen:
                    self._send_code(curlen, _BT)
                    count -= 1
                self._send_code(16, _BT)
                self._send_bits(count - 3, 2)
            elif count <= 10:
                self._send_code(17, _BT)
                self._send_bits(count - 3, 3)
            else:
                self._send_code(18, _BT)
                self._send_bits(count - 11, 7)
            count = 0
            prevlen = curlen
            if nextlen == 0:
                max_count = 138
                min_count = 3
            elif curlen == nextlen:
                max_count = 6
                min_count = 3
            else:
                max_count = 7
                min_count = 4

    def _build_bl_tree(mut self) -> Int:
        self._scan_tree(_LT, self.l_max)
        self._scan_tree(_DT, self.d_max)
        self.bl_max = self._build_tree(_BT, -1, 2, 0, BL_CODES, 7)
        var t = _pu16(self.ct)
        var max_blindex = BL_CODES - 1
        while max_blindex >= 3:
            if t.unsafe_offset(_BT + 2 * Int(_BL_ORDER[max_blindex]) + 1)[] != 0:
                break
            max_blindex -= 1
        self.opt_len += 3 * (max_blindex + 1) + 5 + 5 + 4
        return max_blindex

    def _send_all_trees(mut self, lcodes: Int, dcodes: Int, blcodes: Int):
        var t = _pu16(self.ct)
        self._send_bits(lcodes - 257, 5)
        self._send_bits(dcodes - 1, 5)
        self._send_bits(blcodes - 4, 4)
        for rank in range(blcodes):
            self._send_bits(Int(t.unsafe_offset(_BT + 2 * Int(_BL_ORDER[rank]) + 1)[]), 3)
        self._send_tree(_LT, lcodes - 1)
        self._send_tree(_DT, dcodes - 1)

    def _tr_stored_block(mut self, win_off: Int, stored_len: Int, last: Int):
        self._send_bits((0 << 1) + last, 3)
        self._bi_windup()
        self._put_short(stored_len)
        self._put_short(~stored_len)
        if stored_len > 0:
            unsafe_memcpy(dest=_pu8(self.pending_buf).unsafe_offset(self.pending), src=_pu8(self.window).unsafe_offset(win_off), count=stored_len)
        self.pending += stored_len

    def _compress_block(mut self, ltb: Int, dtb: Int):
        var bl = Pointer(to=global_constant[_BASELEN]()).unsafe_bitcast[UInt16]()
        var bd = Pointer(to=global_constant[_BASEDIST]()).unsafe_bitcast[UInt16]()
        var sx = 0
        while sx < self.sym_next:
            var dist = Int(self.sym_d[sx])
            var lc = Int(self.sym_l[sx])
            sx += 1
            if dist == 0:
                self._send_code(lc, ltb)
            else:
                var code = _lencode(lc)
                self._send_code(code + LITERALS + 1, ltb)
                var extra = _extra_bits(0, code)
                if extra != 0:
                    lc -= Int(bl.unsafe_offset(code)[])
                    self._send_bits(lc, extra)
                dist -= 1
                code = _d_code(dist)
                self._send_code(code, dtb)
                extra = _extra_bits(1, code)
                if extra != 0:
                    dist -= Int(bd.unsafe_offset(code)[])
                    self._send_bits(dist, extra)
        self._send_code(END_BLOCK, ltb)

    def _tr_flush_block(mut self, buf_off: Int, stored_len: Int, last: Int):
        var opt_lenb: Int
        var static_lenb: Int
        var max_blindex = 0
        if self.level > 0:
            self.l_max = self._build_tree(_LT, _SLT, 0, LITERALS + 1, L_CODES, MAX_BITS)
            self.d_max = self._build_tree(_DT, _SDT, 1, 0, D_CODES, MAX_BITS)
            max_blindex = self._build_bl_tree()
            opt_lenb = (self.opt_len + 3 + 7) >> 3
            static_lenb = (self.static_len + 3 + 7) >> 3
            if static_lenb <= opt_lenb:
                opt_lenb = static_lenb
        else:
            opt_lenb = stored_len + 5
            static_lenb = opt_lenb
        if stored_len + 4 <= opt_lenb and buf_off >= 0:
            self._tr_stored_block(buf_off, stored_len, last)
        elif static_lenb == opt_lenb:
            self._send_bits((1 << 1) + last, 3)
            self._compress_block(_SLT, _SDT)
        else:
            self._send_bits((2 << 1) + last, 3)
            self._send_all_trees(self.l_max + 1, self.d_max + 1, max_blindex + 1)
            self._compress_block(_LT, _DT)
        self._init_block()
        if last != 0:
            self._bi_windup()

    @always_inline
    def _tally_lit(mut self, c: Int) -> Bool:
        self.sym_d[self.sym_next] = 0
        self.sym_l[self.sym_next] = UInt8(c)
        self.sym_next += 1
        var t = _pu16(self.ct)
        t.unsafe_offset(_LT + 2 * c)[] += 1
        return self.sym_next == self.sym_end

    @always_inline
    def _tally_dist(mut self, distance: Int, length: Int) -> Bool:
        self.sym_d[self.sym_next] = UInt16(distance)
        self.sym_l[self.sym_next] = UInt8(length)
        self.sym_next += 1
        self.matches += 1
        var t = _pu16(self.ct)
        t.unsafe_offset(_LT + 2 * (_lencode(length) + LITERALS + 1))[] += 1
        t.unsafe_offset(_DT + 2 * _d_code(distance - 1))[] += 1
        return self.sym_next == self.sym_end

    # ---- deflate.c -----------------------------------------------------------------------------------------

    @always_inline
    def _avail_in(self) -> Int:
        return self.in_len - self.in_pos

    def _slide_hash(mut self):
        var wsize = self.w_size
        var h = _pu16(self.head)
        for i in range(self.hash_size):
            var m = Int(h.unsafe_offset(i)[])
            h.unsafe_offset(i)[] = UInt16(m - wsize if m >= wsize else 0)
        var p = _pu16(self.prev)
        for i in range(wsize):
            var m = Int(p.unsafe_offset(i)[])
            p.unsafe_offset(i)[] = UInt16(m - wsize if m >= wsize else 0)

    def _read_buf(mut self, dst: Pointer[UInt8, MutUntrackedOrigin], size: Int) -> Int:
        var ln = min(self._avail_in(), size)
        if ln == 0:
            return 0
        unsafe_memcpy(dest=dst, src=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.in_addr + self.in_pos), count=ln)
        self.in_pos += ln
        return ln

    @always_inline
    def _update_hash(mut self, c: Int):
        self.ins_h = ((self.ins_h << self.hash_shift) ^ c) & self.hash_mask

    @always_inline
    def _insert_string(mut self, pos: Int) -> Int:
        var win = _pu8(self.window)
        self._update_hash(Int(win.unsafe_offset(pos + MIN_MATCH - 1)[]))
        var h = _pu16(self.head)
        var mh = h.unsafe_offset(self.ins_h)[]
        _pu16(self.prev).unsafe_offset(pos & self.w_mask)[] = mh
        h.unsafe_offset(self.ins_h)[] = UInt16(pos)
        return Int(mh)

    def _clear_hash(mut self):
        var h = _pu16(self.head)
        for i in range(self.hash_size):
            h.unsafe_offset(i)[] = 0

    def _fill_window(mut self):
        var wsize = self.w_size
        var win = _pu8(self.window)
        while True:
            var more = self.window_size - self.lookahead - self.strstart
            if self.strstart >= wsize + (wsize - MIN_LOOKAHEAD):
                unsafe_memcpy(dest=win, src=win.unsafe_offset(wsize), count=wsize - more)
                self.match_start -= wsize
                self.strstart -= wsize
                self.block_start -= wsize
                if self.insert > self.strstart:
                    self.insert = self.strstart
                self._slide_hash()
                more += wsize
            if self._avail_in() == 0:
                break
            var n = self._read_buf(win.unsafe_offset(self.strstart + self.lookahead), more)
            self.lookahead += n
            if self.lookahead + self.insert >= MIN_MATCH:
                var pos = self.strstart - self.insert
                self.ins_h = Int(win.unsafe_offset(pos)[])
                self._update_hash(Int(win.unsafe_offset(pos + 1)[]))
                while self.insert != 0:
                    self._update_hash(Int(win.unsafe_offset(pos + MIN_MATCH - 1)[]))
                    _pu16(self.prev).unsafe_offset(pos & self.w_mask)[] = _pu16(self.head).unsafe_offset(self.ins_h)[]
                    _pu16(self.head).unsafe_offset(self.ins_h)[] = UInt16(pos)
                    pos += 1
                    self.insert -= 1
                    if self.lookahead + self.insert < MIN_MATCH:
                        break
            if not (self.lookahead < MIN_LOOKAHEAD and self._avail_in() != 0):
                break
        if self.high_water < self.window_size:
            var curr = self.strstart + self.lookahead
            if self.high_water < curr:
                var init = self.window_size - curr
                if init > WIN_INIT:
                    init = WIN_INIT
                for i in range(init):
                    win.unsafe_offset(curr + i)[] = 0
                self.high_water = curr + init
            elif self.high_water < curr + WIN_INIT:
                var init = curr + WIN_INIT - self.high_water
                if init > self.window_size - self.high_water:
                    init = self.window_size - self.high_water
                for i in range(init):
                    win.unsafe_offset(self.high_water + i)[] = 0
                self.high_water += init

    def _flush_pending(mut self):
        self._bi_flush()
        var ln = min(self.pending, self.avail_out)
        if ln == 0:
            return
        unsafe_memcpy(dest=_pu8(self.out).unsafe_offset(self.out_pos), src=_pu8(self.pending_buf).unsafe_offset(self.pending_out), count=ln)
        self.out_pos += ln
        self.pending_out += ln
        self.avail_out -= ln
        self.pending -= ln
        if self.pending == 0:
            self.pending_out = 0

    def _longest_match(mut self, cur_match_in: Int) -> Int:
        var cur_match = cur_match_in
        var chain_length = self.max_chain_length
        var win = _pu8(self.window)
        var scan = self.strstart
        var best_len = self.prev_length
        var nice_match = self.nice_match
        var max_dist = self.w_size - MIN_LOOKAHEAD
        var limit = self.strstart - max_dist if self.strstart > max_dist else 0
        var prv = _pu16(self.prev)
        var wmask = self.w_mask
        var scan_end1 = win.unsafe_offset(scan + best_len - 1)[]
        var scan_end = win.unsafe_offset(scan + best_len)[]
        if self.prev_length >= self.good_match:
            chain_length >>= 2
        if nice_match > self.lookahead:
            nice_match = self.lookahead
        while True:
            var mt = cur_match
            if (win.unsafe_offset(mt + best_len)[] == scan_end
                and win.unsafe_offset(mt + best_len - 1)[] == scan_end1
                and win.unsafe_offset(mt)[] == win.unsafe_offset(scan)[]
                and win.unsafe_offset(mt + 1)[] == win.unsafe_offset(scan + 1)[]):
                var s = scan + 2
                var m = mt + 2
                var strend = scan + MAX_MATCH
                while True:
                    # up to eight compares, then the end test, as zlib does
                    var k = 0
                    var same = True
                    while k < 8:
                        s += 1
                        m += 1
                        if win.unsafe_offset(s)[] != win.unsafe_offset(m)[]:
                            same = False
                            break
                        k += 1
                    if not same or s >= strend:
                        break
                var ln = MAX_MATCH - (strend - s)
                if ln > best_len:
                    self.match_start = cur_match
                    best_len = ln
                    if ln >= nice_match:
                        break
                    scan_end1 = win.unsafe_offset(scan + best_len - 1)[]
                    scan_end = win.unsafe_offset(scan + best_len)[]
            cur_match = Int(prv.unsafe_offset(cur_match & wmask)[])
            if cur_match <= limit:
                break
            chain_length -= 1
            if chain_length == 0:
                break
        if best_len <= self.lookahead:
            return best_len
        return self.lookahead

    def _flush_block_only(mut self, last: Int):
        self._tr_flush_block(self.block_start if self.block_start >= 0 else -1, self.strstart - self.block_start, last)
        self.block_start = self.strstart
        self._flush_pending()

    def _deflate_stored(mut self, flush: Int) -> Int:
        var min_block = min(self.pending_buf_size - 5, self.w_size)
        var last = 0
        var used = self._avail_in()
        while True:
            var ln = MAX_STORED
            var have = (self.bi_valid + 42) >> 3
            if self.avail_out < have:
                break
            have = self.avail_out - have
            var left = self.strstart - self.block_start
            if ln > left + self._avail_in():
                ln = left + self._avail_in()
            if ln > have:
                ln = have
            if ln < min_block and ((ln == 0 and flush != Z_FINISH) or flush == Z_NO_FLUSH or ln != left + self._avail_in()):
                break
            last = 1 if (flush == Z_FINISH and ln == left + self._avail_in()) else 0
            self._tr_stored_block(-1, 0, last)
            var pb = _pu8(self.pending_buf)
            pb.unsafe_offset(self.pending - 4)[] = UInt8(ln & 0xFF)
            pb.unsafe_offset(self.pending - 3)[] = UInt8((ln >> 8) & 0xFF)
            pb.unsafe_offset(self.pending - 2)[] = UInt8(~ln & 0xFF)
            pb.unsafe_offset(self.pending - 1)[] = UInt8((~ln >> 8) & 0xFF)
            self._flush_pending()
            if left > 0:
                if left > ln:
                    left = ln
                unsafe_memcpy(dest=_pu8(self.out).unsafe_offset(self.out_pos), src=_pu8(self.window).unsafe_offset(self.block_start), count=left)
                self.out_pos += left
                self.avail_out -= left
                self.block_start += left
                ln -= left
            if ln > 0:
                _ = self._read_buf(_pu8(self.out).unsafe_offset(self.out_pos), ln)
                self.out_pos += ln
                self.avail_out -= ln
            if last != 0:
                break
        used -= self._avail_in()
        if used != 0:
            if used >= self.w_size:
                self.matches = 2
                unsafe_memcpy(dest=_pu8(self.window), src=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.in_addr + self.in_pos - self.w_size), count=self.w_size)
                self.strstart = self.w_size
                self.insert = self.strstart
            else:
                if self.window_size - self.strstart <= used:
                    self.strstart -= self.w_size
                    unsafe_memcpy(dest=_pu8(self.window), src=_pu8(self.window).unsafe_offset(self.w_size), count=self.strstart)
                    if self.matches < 2:
                        self.matches += 1
                    if self.insert > self.strstart:
                        self.insert = self.strstart
                unsafe_memcpy(dest=_pu8(self.window).unsafe_offset(self.strstart), src=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.in_addr + self.in_pos - used), count=used)
                self.strstart += used
                self.insert += min(used, self.w_size - self.insert)
            self.block_start = self.strstart
        if self.high_water < self.strstart:
            self.high_water = self.strstart
        if last != 0:
            return _FINISH_DONE
        if flush != Z_NO_FLUSH and flush != Z_FINISH and self._avail_in() == 0 and self.strstart == self.block_start:
            return _BLOCK_DONE
        var have = self.window_size - self.strstart
        if self._avail_in() > have and self.block_start >= self.w_size:
            self.block_start -= self.w_size
            self.strstart -= self.w_size
            unsafe_memcpy(dest=_pu8(self.window), src=_pu8(self.window).unsafe_offset(self.w_size), count=self.strstart)
            if self.matches < 2:
                self.matches += 1
            have += self.w_size
            if self.insert > self.strstart:
                self.insert = self.strstart
        if have > self._avail_in():
            have = self._avail_in()
        if have > 0:
            _ = self._read_buf(_pu8(self.window).unsafe_offset(self.strstart), have)
            self.strstart += have
            self.insert += min(have, self.w_size - self.insert)
        if self.high_water < self.strstart:
            self.high_water = self.strstart
        have = (self.bi_valid + 42) >> 3
        have = min(self.pending_buf_size - have, MAX_STORED)
        min_block = min(have, self.w_size)
        var left = self.strstart - self.block_start
        if left >= min_block or ((left != 0 or flush == Z_FINISH) and flush != Z_NO_FLUSH and self._avail_in() == 0 and left <= have):
            var ln = min(left, have)
            last = 1 if (flush == Z_FINISH and self._avail_in() == 0 and ln == left) else 0
            self._tr_stored_block(self.block_start, ln, last)
            self.block_start += ln
            self._flush_pending()
        return _FINISH_STARTED if last != 0 else _NEED_MORE

    def _deflate_fast(mut self, flush: Int) -> Int:
        var max_dist = self.w_size - MIN_LOOKAHEAD
        while True:
            if self.lookahead < MIN_LOOKAHEAD:
                self._fill_window()
                if self.lookahead < MIN_LOOKAHEAD and flush == Z_NO_FLUSH:
                    return _NEED_MORE
                if self.lookahead == 0:
                    break
            var hash_head = 0
            if self.lookahead >= MIN_MATCH:
                hash_head = self._insert_string(self.strstart)
            if hash_head != 0 and self.strstart - hash_head <= max_dist:
                self.match_length = self._longest_match(hash_head)
            var bflush: Bool
            if self.match_length >= MIN_MATCH:
                bflush = self._tally_dist(self.strstart - self.match_start, self.match_length - MIN_MATCH)
                self.lookahead -= self.match_length
                if self.match_length <= self.max_lazy_match and self.lookahead >= MIN_MATCH:
                    self.match_length -= 1
                    while True:
                        self.strstart += 1
                        _ = self._insert_string(self.strstart)
                        self.match_length -= 1
                        if self.match_length == 0:
                            break
                    self.strstart += 1
                else:
                    self.strstart += self.match_length
                    self.match_length = 0
                    var win = _pu8(self.window)
                    self.ins_h = Int(win.unsafe_offset(self.strstart)[])
                    self._update_hash(Int(win.unsafe_offset(self.strstart + 1)[]))
            else:
                bflush = self._tally_lit(Int(_pu8(self.window).unsafe_offset(self.strstart)[]))
                self.lookahead -= 1
                self.strstart += 1
            if bflush:
                self._flush_block_only(0)
                if self.avail_out == 0:
                    return _NEED_MORE
        self.insert = self.strstart if self.strstart < MIN_MATCH - 1 else MIN_MATCH - 1
        if flush == Z_FINISH:
            self._flush_block_only(1)
            if self.avail_out == 0:
                return _FINISH_STARTED
            return _FINISH_DONE
        if self.sym_next != 0:
            self._flush_block_only(0)
            if self.avail_out == 0:
                return _NEED_MORE
        return _BLOCK_DONE

    def _deflate_slow(mut self, flush: Int) -> Int:
        var max_dist = self.w_size - MIN_LOOKAHEAD
        while True:
            if self.lookahead < MIN_LOOKAHEAD:
                self._fill_window()
                if self.lookahead < MIN_LOOKAHEAD and flush == Z_NO_FLUSH:
                    return _NEED_MORE
                if self.lookahead == 0:
                    break
            var hash_head = 0
            if self.lookahead >= MIN_MATCH:
                hash_head = self._insert_string(self.strstart)
            self.prev_length = self.match_length
            self.prev_match = self.match_start
            self.match_length = MIN_MATCH - 1
            if hash_head != 0 and self.prev_length < self.max_lazy_match and self.strstart - hash_head <= max_dist:
                self.match_length = self._longest_match(hash_head)
                if self.match_length <= 5 and (self.match_length == MIN_MATCH and self.strstart - self.match_start > TOO_FAR):
                    self.match_length = MIN_MATCH - 1
            if self.prev_length >= MIN_MATCH and self.match_length <= self.prev_length:
                var max_insert = self.strstart + self.lookahead - MIN_MATCH
                var bflush = self._tally_dist(self.strstart - 1 - self.prev_match, self.prev_length - MIN_MATCH)
                self.lookahead -= self.prev_length - 1
                self.prev_length -= 2
                while True:
                    self.strstart += 1
                    if self.strstart <= max_insert:
                        _ = self._insert_string(self.strstart)
                    self.prev_length -= 1
                    if self.prev_length == 0:
                        break
                self.match_available = 0
                self.match_length = MIN_MATCH - 1
                self.strstart += 1
                if bflush:
                    self._flush_block_only(0)
                    if self.avail_out == 0:
                        return _NEED_MORE
            elif self.match_available != 0:
                var bflush = self._tally_lit(Int(_pu8(self.window).unsafe_offset(self.strstart - 1)[]))
                if bflush:
                    self._flush_block_only(0)
                self.strstart += 1
                self.lookahead -= 1
                if self.avail_out == 0:
                    return _NEED_MORE
            else:
                self.match_available = 1
                self.strstart += 1
                self.lookahead -= 1
        if self.match_available != 0:
            _ = self._tally_lit(Int(_pu8(self.window).unsafe_offset(self.strstart - 1)[]))
            self.match_available = 0
        self.insert = self.strstart if self.strstart < MIN_MATCH - 1 else MIN_MATCH - 1
        if flush == Z_FINISH:
            self._flush_block_only(1)
            if self.avail_out == 0:
                return _FINISH_STARTED
            return _FINISH_DONE
        if self.sym_next != 0:
            self._flush_block_only(0)
            if self.avail_out == 0:
                return _NEED_MORE
        return _BLOCK_DONE

    def deflate(mut self, flush: Int) -> Int:
        """zlib deflate() for a raw stream with Z_NO_FLUSH or Z_FINISH; the caller sets avail_out > 0."""
        if self.avail_out == 0:
            return Z_BUF_ERROR
        var old_flush = self.last_flush
        self.last_flush = flush
        if self.pending != 0:
            self._flush_pending()
            if self.avail_out == 0:
                self.last_flush = -1
                return Z_OK
        elif self._avail_in() == 0 and (flush * 2) <= (old_flush * 2) and flush != Z_FINISH:
            return Z_BUF_ERROR
        if self.status == 1 and self._avail_in() != 0:
            return Z_BUF_ERROR
        if self._avail_in() != 0 or self.lookahead != 0 or (flush != Z_NO_FLUSH and self.status != 1):
            var bstate: Int
            if self.level == 0:
                bstate = self._deflate_stored(flush)
            elif Int(_CFG[self.level * 5 + 4]) == 1:
                bstate = self._deflate_fast(flush)
            else:
                bstate = self._deflate_slow(flush)
            if bstate == _FINISH_STARTED or bstate == _FINISH_DONE:
                self.status = 1
            if bstate == _NEED_MORE or bstate == _FINISH_STARTED:
                if self.avail_out == 0:
                    self.last_flush = -1
                return Z_OK
            if bstate == _BLOCK_DONE:
                self._tr_stored_block(-1, 0, 0)
                self._flush_pending()
                if self.avail_out == 0:
                    self.last_flush = -1
                    return Z_OK
        if flush != Z_FINISH:
            return Z_OK
        return Z_STREAM_END


# CPython's zlib module grows its output in these blocks (Include/internal/pycore_blocks_output_buffer.h)
def _block_size(i: Int) -> Int:
    if i == 0:
        return 32 * 1024
    if i == 1:
        return 64 * 1024
    if i == 2:
        return 256 * 1024
    if i == 3:
        return 1024 * 1024
    if i == 4:
        return 4 * 1024 * 1024
    if i == 5:
        return 8 * 1024 * 1024
    if i < 8:
        return 16 * 1024 * 1024
    if i < 12:
        return 32 * 1024 * 1024
    if i < 14:
        return 64 * 1024 * 1024
    if i < 16:
        return 128 * 1024 * 1024
    return 256 * 1024 * 1024


def _run(mut d: Deflater, flush: Int, bound: Int):
    """One CPython-style call: offer output room (CPython's block schedule for level 0, one bound-sized block
    otherwise), call deflate until it stops filling the room."""
    var block = 0
    var total = 0
    while True:
        var room = _block_size(block) if d.level == 0 else bound
        block += 1
        d.out.resize(total + room, 0)
        d.avail_out = room
        d.out_pos = total
        var rc = d.deflate(flush)
        total = d.out_pos
        if d.avail_out != 0 or rc == Z_STREAM_END:
            break
    d.out.shrink(total)


def deflate_raw(data: Span[UInt8, _], level: Int = -1, stream: Bool = False) raises -> List[UInt8]:
    """Raw deflate of data, byte-identical with CPython: zlib.compress(data, level, wbits=-15), or with
    stream=True zlib.compressobj(level, DEFLATED, -15) fed the whole data then flushed (what zipfile does)."""
    if level < -1 or level > 9:
        if stream:
            raise Error("ValueError: Invalid initialization option")
        raise Error("error: Bad compression level")
    var d = Deflater(level)
    d.in_addr = Int(data.unsafe_ptr())
    d.in_len = len(data)
    var bound = len(data) + (len(data) >> 3) + (len(data) >> 8) + (len(data) >> 12) + 1024
    if stream:
        _run(d, Z_NO_FLUSH, bound)
        var first = d.out.copy()
        d.out = List[UInt8]()
        _run(d, Z_FINISH, bound)
        first.extend(Span(d.out))
        return first^
    _run(d, Z_FINISH, bound)
    var res = List[UInt8]()
    swap(res, d.out)
    return res^
