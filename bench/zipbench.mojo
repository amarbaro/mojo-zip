# Hot paths of mojo-zip, same jobs and fixtures as tools/bench_ref.py. Usage: zipbench many|stored|stored_view|deflate|text|compress
from std.sys import argv
from std.time import perf_counter_ns
from std.benchmark import keep
from zipfile import ZipReader, ZipWriter, ZIP_DEFLATED
from deflate import crc32


def main() raises:
    var which = String(argv()[1])
    var t0 = perf_counter_ns()
    var check = String()
    if which == "many":
        var z = ZipReader.open(".work/bench/many.zip")
        var total = 0
        for i in range(len(z.infolist())):
            total += z.infolist()[i].file_size
        keep(total)
        check = "entries " + String(len(z.namelist())) + " bytes " + String(total)
    elif which == "stored_view":
        var z = ZipReader.open(".work/bench/big_stored.zip")
        var v = z.read_view("big.bin")
        check = "bytes " + String(len(v)) + " crc " + String(crc32(v))
    elif which == "compress":
        var words = List[String]()
        for w in String("alpha |beta |gamma |delta\n|epsilon, |zeta. |the |of |a |mojo |zip ").split("|"):
            words.append(String(w))
        var buf = List[UInt8]()
        var x = 12345
        while len(buf) < (16 << 20):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            buf.extend(words[(x >> 16) % len(words)].as_bytes())
        buf.shrink(16 << 20)
        t0 = perf_counter_ns()
        var w = ZipWriter(ZIP_DEFLATED, 6)
        w.writestr("t", Span(buf))
        w.close()
        check = "bytes " + String(len(w.to_bytes()))
    else:
        var z = ZipReader.open(".work/bench/big_" + which + ".zip")
        var data = z.read("big.bin")
        check = "bytes " + String(len(data)) + " crc " + String(crc32(Span(data)))
    var t1 = perf_counter_ns()
    print("mojo", which, "ms", (t1 - t0) // 1_000_000, check)
