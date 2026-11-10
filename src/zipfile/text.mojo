"""Text helpers zipfile needs: cp437 and UTF-8 names, Python-style repr of str and bytes (error texts quote names)."""
from .printable import is_printable

comptime _CP437 = SIMD[DType.uint16, 128](
    199, 252, 233, 226, 228, 224, 229, 231, 234, 235, 232, 239, 238, 236, 196, 197, 201, 230, 198, 244, 246, 242, 251, 249,
    255, 214, 220, 162, 163, 165, 8359, 402, 225, 237, 243, 250, 241, 209, 170, 186, 191, 8976, 172, 189, 188, 161, 171, 187,
    9617, 9618, 9619, 9474, 9508, 9569, 9570, 9558, 9557, 9571, 9553, 9559, 9565, 9564, 9563, 9488, 9492, 9524, 9516, 9500,
    9472, 9532, 9566, 9567, 9562, 9556, 9577, 9574, 9568, 9552, 9580, 9575, 9576, 9572, 9573, 9561, 9560, 9554, 9555, 9579,
    9578, 9496, 9484, 9608, 9604, 9612, 9616, 9600, 945, 223, 915, 960, 931, 963, 181, 964, 934, 920, 937, 948, 8734, 966,
    949, 8745, 8801, 177, 8805, 8804, 8992, 8993, 247, 8776, 176, 8729, 183, 8730, 8319, 178, 9632, 160)


def cp437_decode(b: Span[UInt8, _]) -> String:
    var s = String()
    for i in range(len(b)):
        var c = Int(b[i])
        s += chr(c if c < 128 else Int(_CP437[c - 128]))
    return s^


def cp437_encode(s: String, mut out: List[UInt8]) -> Bool:
    """Appends the cp437 bytes of s; False (out untouched) when a character has none."""
    var tmp = List[UInt8]()
    for cp in s.codepoints():
        var c = Int(cp.to_u32())
        if c < 128:
            tmp.append(UInt8(c))
            continue
        var found = -1
        for k in range(128):
            if Int(_CP437[k]) == c:
                found = k + 128
                break
        if found < 0:
            return False
        tmp.append(UInt8(found))
    out.extend(Span(tmp))
    return True


def utf8_valid(b: Span[UInt8, _]) -> Bool:
    """Strict UTF-8 as Python's codec: no overlongs, surrogates or code points above U+10FFFF."""
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        var need = 0
        var lo = 0x80
        var hi = 0xBF
        if c < 0x80:
            i += 1
            continue
        elif c >= 0xC2 and c <= 0xDF:
            need = 1
        elif c == 0xE0:
            need = 2
            lo = 0xA0
        elif c >= 0xE1 and c <= 0xEF:
            need = 2
            if c == 0xED:
                hi = 0x9F
        elif c == 0xF0:
            need = 3
            lo = 0x90
        elif c >= 0xF1 and c <= 0xF3:
            need = 3
        elif c == 0xF4:
            need = 3
            hi = 0x8F
        else:
            return False
        if i + need >= n:
            return False
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def utf8_string(b: Span[UInt8, _]) -> String:
    """The bytes as a String (call only after utf8_valid)."""
    return String(unsafe_from_utf8=b)


def _printable(c: Int) -> Bool:
    return is_printable(c)


def _hexd(v: Int, width: Int) -> String:
    var digits = "0123456789abcdef"
    var s = String()
    for k in range(width - 1, -1, -1):
        s += String(digits[byte = (v >> (4 * k)) & 15])
    return s^


def repr_str(s: String) -> String:
    """Python repr(str)."""
    var has_sq = False
    var has_dq = False
    for cp in s.codepoints():
        var c = Int(cp.to_u32())
        if c == 39:
            has_sq = True
        elif c == 34:
            has_dq = True
    var q = 34 if (has_sq and not has_dq) else 39
    var out = String()
    out += chr(q)
    for cp in s.codepoints():
        var c = Int(cp.to_u32())
        if c == q or c == 92:
            out += "\\"
            out += chr(c)
        elif c == 9:
            out += "\\t"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif _printable(c):
            out += chr(c)
        elif c < 0x100:
            out += "\\x" + _hexd(c, 2)
        elif c < 0x10000:
            out += "\\u" + _hexd(c, 4)
        else:
            out += "\\U" + _hexd(c, 8)
    out += chr(q)
    return out^


def repr_bytes(b: Span[UInt8, _]) -> String:
    """Python repr(bytes)."""
    var has_sq = False
    var has_dq = False
    for i in range(len(b)):
        if b[i] == 39:
            has_sq = True
        elif b[i] == 34:
            has_dq = True
    var q = 34 if (has_sq and not has_dq) else 39
    var out = String("b")
    out += chr(q)
    for i in range(len(b)):
        var c = Int(b[i])
        if c == q or c == 92:
            out += "\\"
            out += chr(c)
        elif c == 9:
            out += "\\t"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c < 0x20 or c >= 0x7F:
            out += "\\x" + _hexd(c, 2)
        else:
            out += chr(c)
    out += chr(q)
    return out^
