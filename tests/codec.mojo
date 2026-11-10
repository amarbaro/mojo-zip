"""Codec test runner. Replays DIR/manifest.txt through src/deflate and writes the results into DIR/out.
Usage: codec DIR. tools/codec_corpus.py --verify compares the results with zlib."""
from std.sys import argv
from deflate import deflate_raw, inflate_raw, crc32, INF_END, INF_LIMIT, INF_INPUT, INF_BAD


def _write(path: String, data: Span[UInt8, _]) raises:
    var f = open(path, "w")
    f.write_bytes(data)


def main() raises:
    var d = String(argv()[1])
    var lines = open(d + "/manifest.txt", "r").read().split("\n")
    for ln in lines:
        var parts = ln.split(" ")
        if len(parts) != 2:
            continue
        var op = String(parts[0])
        var name = String(parts[1])
        if op == "deflate":
            var data = open(d + "/in/" + name + ".bin", "r").read_bytes()
            for lv in range(-1, 10):
                var modes = String("o") if lv not in (-1, 0, 6) else String("os")
                for mi in range(modes.byte_length()):
                    var stream = modes[byte = mi] == "s"
                    var o = deflate_raw(Span(data), lv, stream)
                    _write(d + "/out/" + name + "." + String(lv) + "." + String(modes[byte = mi]), Span(o))
        else:
            var z = open(d + "/raw/" + name + ".raw", "r").read_bytes()
            var r = inflate_raw(Span(z))
            var st = String("END") if r.status == INF_END else (String("INPUT") if r.status == INF_INPUT else String("BAD"))
            var f = open(d + "/out/" + name + ".inf", "w")
            f.write(st, " ", Int(crc32(Span(r.out))), " ", len(r.out), " ", r.consumed, " ", r.msg, "\n")
