---
name: mojo-zip
description: "Read and write ZIP archives from Mojo with CPython zipfile's behaviour and error texts: stored and deflated members, zip64, CRC-32, comments. Pure Mojo, no libz, no FFI; deflate output is byte-identical with zlib at levels 0..9. Use when Mojo code must read or build a .zip that Python's zipfile also reads, or needs raw deflate, inflate or crc32."
---

# mojo-zip

`zipfile` for Mojo 1.2 in pure Mojo. The deflate codec is a port of zlib 1.3.2, so the bytes match `zlib` at every level.

## Install

`mojo build -I <repo>/src app.mojo`, or `mojo precompile <repo>/src/zipfile -o zipfile.mojoc` (it imports `deflate`,
precompile `src/deflate` too), or copy `src/zipfile/` and `src/deflate/`.

## Use

```mojo
from zipfile import ZipReader, ZipWriter, ZIP_DEFLATED


def main() raises:
    var w = ZipWriter(ZIP_DEFLATED, 6)
    w.writestr("hello.txt", "hello zip, hello zip, hello zip".as_bytes())
    w.mkdir("docs")
    w.close()
    var z = ZipReader.from_bytes(w.to_bytes())
    print(String(unsafe_from_utf8=Span(z.read("hello.txt"))))
    print(len(z), z.infolist()[0].compress_size, z.testzip() == None)
```

Files: `ZipWriter.create(path, ZIP_DEFLATED, 6)` then `close()`; `ZipReader.open(path)`.
Codec alone: `from deflate import deflate_raw, inflate, crc32`.

## The calls that cover 90%

- `ZipReader.open(path)`, `ZipReader.from_bytes(bytes)`; then `namelist()`, `getinfo(name)`, `read(name)`, `testzip()`.
- `read_view(name)` returns a `Span` into the archive for a STORED member, no copy. It lives as long as the reader.
- `ZipWriter(compression, level)` or `ZipWriter.create(path, ...)`; `writestr(name, data)`, `mkdir(name)`,
  `set_comment(bytes)`, `close()`, `to_bytes()` (after `close`).
- `deflate_raw(data, level)` equals `zlib.compress(data, level, wbits=-15)`; `stream=True` equals what `zipfile` writes.
- `inflate(bytes)` raises zlib's texts; `inflate_raw` never raises, read `.status`.

## Rules

- Errors are `Error` text `<PythonClass>: <message>` as CPython raises (`BadZipFile: File is not a zip file`,
  `KeyError: There is no item named 'x' in the archive`). Match with `String(err)`, do not assume a clean archive.
- The reader holds the whole archive in memory (no mmap). 64-bit sizes and offsets saturate at 2^61.
- `writestr` date: year 0 (the default) is `SOURCE_DATE_EPOCH` if set, else 1980-01-01; it never reads the clock.
- Compression types 12 (bzip2), 14 (lzma) and 93 (zstd) raise `NotImplementedError: compression type N (...)`; any
  other unknown type raises `That compression method is not supported`.
- Not there: encryption, append mode, `remove`, streaming `open(..., 'w')`, `extract*`, `Path`, `metadata_encoding`,
  `printdir`, `is_zipfile`.
- Level 0 output depends on CPython's output-block schedule; `deflate_raw` models it, do not re-chunk the input.
- Run every build under a memory cap: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 -- <cmd>`.

## Gate

`scripts/check.sh` (needs `uv sync` for the Python oracle); full output in `.work/native-gate.txt`.
`scripts/ci.sh` adds the mutants, the API check, the quickstart and the README example.
